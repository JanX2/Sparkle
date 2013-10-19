//
//  SUBasicUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 4/23/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUBasicUpdateDriver.h"
#import "SUHost.h"
#import "SUDSAVerifier.h"
#import "SUInstaller.h"
#import "SUStandardVersionComparator.h"
#import "SUUnarchiver.h"
#import "SUConstants.h"
#import "SULog.h"
#import "SUPlainInstaller.h"
#import "SUPlainInstallerInternals.h"
#import "SUBinaryDeltaCommon.h"
#import "SUCodeSigningVerifier.h"
#import "SUUpdater_Private.h"

@interface SUBasicUpdateDriver () <SUUnarchiverDelegate> {
	NSString *_tempDir;
	NSString *_relaunchPath;
}

@property (nonatomic, strong, readwrite) SUAppcastItem *updateItem;
@property (nonatomic, strong) SUAppcastItem *nonDeltaUpdateItem;

@property (nonatomic, strong, readwrite) NSURLDownload *download;
@property (nonatomic, strong, readwrite) NSString *downloadPath;

@end

@implementation SUBasicUpdateDriver

- (void)checkForUpdatesAtURL:(NSURL *)URL host:(SUHost *)aHost
{	
	[super checkForUpdatesAtURL:URL host:aHost];
	if ([aHost isRunningOnReadOnlyVolume])
	{
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURunningFromDiskImageError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:SULocalizedString(@"%1$@ can't be updated when it's running from a read-only volume like a disk image or an optical drive. Move %1$@ to your Applications folder, relaunch it from there, and try again.", nil), [aHost name]] forKey:NSLocalizedDescriptionKey]]];
		return;
	}	
	
	SUAppcast *appcast = [[SUAppcast alloc] init];
	[appcast setDelegate:self];
	[appcast setUserAgentString:self.updater.userAgentString];
	[appcast fetchAppcastFromURL:URL];
}

- (id <SUVersionComparison>)versionComparator
{
	id <SUVersionComparison> comparator = nil;
	
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	
	// Give the delegate a chance to provide a custom version comparator
	if ([delegate respondsToSelector:@selector(versionComparatorForUpdater:)])
		comparator = [delegate versionComparatorForUpdater:self.updater];
	
	// If we don't get a comparator from the delegate, use the default comparator
	if (!comparator)
		comparator = [SUStandardVersionComparator defaultComparator];
	
	return comparator;	
}

- (BOOL)isItemNewer:(SUAppcastItem *)ui
{
	return [[self versionComparator] compareVersion:self.host.version toVersion:[ui versionString]] == NSOrderedAscending;
}

- (BOOL)hostSupportsItem:(SUAppcastItem *)ui
{
	if (([ui minimumSystemVersion] == nil || [[ui minimumSystemVersion] isEqualToString:@""]) && 
        ([ui maximumSystemVersion] == nil || [[ui maximumSystemVersion] isEqualToString:@""])) { return YES; }
    
    BOOL minimumVersionOK = TRUE;
    BOOL maximumVersionOK = TRUE;
    
    // Check minimum and maximum System Version
    if ([ui minimumSystemVersion] != nil && ![[ui minimumSystemVersion] isEqualToString:@""]) {
        minimumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui minimumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedDescending;
    }
    if ([ui maximumSystemVersion] != nil && ![[ui maximumSystemVersion] isEqualToString:@""]) {
        maximumVersionOK = [[SUStandardVersionComparator defaultComparator] compareVersion:[ui maximumSystemVersion] toVersion:[SUHost systemVersionString]] != NSOrderedAscending;
    }
    
    return minimumVersionOK && maximumVersionOK;
}

- (BOOL)itemContainsSkippedVersion:(SUAppcastItem *)ui
{
	NSString *skippedVersion = [self.host objectForUserDefaultsKey:SUSkippedVersionKey];
	if (skippedVersion == nil) { return NO; }
	return [[self versionComparator] compareVersion:[ui versionString] toVersion:skippedVersion] != NSOrderedDescending;
}

- (BOOL)itemContainsValidUpdate:(SUAppcastItem *)ui
{
	return [self hostSupportsItem:ui] && [self isItemNewer:ui] && ![self itemContainsSkippedVersion:ui];
}

- (void)appcastDidFinishLoading:(SUAppcast *)ac
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	
	if ([delegate respondsToSelector:@selector(updater:didFinishLoadingAppcast:)])
		[delegate updater:self.updater didFinishLoadingAppcast:ac];
    
    SUAppcastItem *item = nil;
    
	// Now we have to find the best valid update in the appcast.
	if ([delegate respondsToSelector:@selector(bestValidUpdateInAppcast:forUpdater:)]) // Does the delegate want to handle it?
	{
		item = [delegate bestValidUpdateInAppcast:ac forUpdater:self.updater];
	}
	else // If not, we'll take care of it ourselves.
	{
		// Find the first update we can actually use.
		NSEnumerator *updateEnumerator = [[ac items] objectEnumerator];
		do {
			item = [updateEnumerator nextObject];
		} while (item && ![self hostSupportsItem:item]);

		SUAppcastItem *deltaUpdateItem = [[item deltaUpdates] objectForKey:self.host.version];
		if (deltaUpdateItem && [self hostSupportsItem:deltaUpdateItem]) {
			self.nonDeltaUpdateItem = item;
			item = deltaUpdateItem;
		}
	}
    
    self.updateItem = item;
	if (!item) {
		[self didNotFindUpdate];
		return;
	}
	
	if ([self itemContainsValidUpdate:item])
		[self didFindValidUpdate];
	else
		[self didNotFindUpdate];
}

- (void)appcast:(SUAppcast *)ac failedToLoadWithError:(NSError *)error
{
	[self abortUpdateWithError:error];
}

- (void)didFindValidUpdate
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	if ([delegate respondsToSelector:@selector(updater:didFindValidUpdate:)])
		[delegate updater:self.updater didFindValidUpdate:self.updateItem];
	[self downloadUpdate];
}

- (void)didNotFindUpdate
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	if ([delegate respondsToSelector:@selector(updaterDidNotFindUpdate:)])
		[delegate updaterDidNotFindUpdate:self.updater];
	
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUNoUpdateError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:SULocalizedString(@"You already have the newest version of %@.", nil), self.host.name] forKey:NSLocalizedDescriptionKey]]];
}

- (void)downloadUpdate
{
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.updateItem.fileURL];
	[request setValue:self.updater.userAgentString forHTTPHeaderField:@"User-Agent"];
	self.download = [[NSURLDownload alloc] initWithRequest:request delegate:self];
}

- (void)download:(NSURLDownload *)d decideDestinationWithSuggestedFilename:(NSString *)name
{
	// If name ends in .txt, the server probably has a stupid MIME configuration. We'll give the developer the benefit of the doubt and chop that off.
	if ([[name pathExtension] isEqualToString:@"txt"])
		name = [name stringByDeletingPathExtension];
	
	NSString *downloadFileName = [NSString stringWithFormat:@"%@ %@", self.host.name, self.updateItem.versionString];
    
    
	_tempDir = [self.host.appSupportPath stringByAppendingPathComponent:downloadFileName];
	int cnt=1;
	while ([[NSFileManager defaultManager] fileExistsAtPath:_tempDir] && cnt <= 999)
	{
		_tempDir = [self.host.appSupportPath stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d", downloadFileName, cnt++]];
	}
	
    // Create the temporary directory if necessary.
	BOOL success = [[NSFileManager defaultManager] createDirectoryAtPath:_tempDir withIntermediateDirectories:YES attributes:nil error:NULL];
	if (!success)
	{
		// Okay, something's really broken with this user's file structure.
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUTemporaryDirectoryError userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Can't make a temporary directory for the update download at %@.",_tempDir] forKey:NSLocalizedDescriptionKey]]];
	}
	
	NSString *downloadPath = [_tempDir stringByAppendingPathComponent:name];
	self.downloadPath = downloadPath;
	[self.download setDestination:downloadPath allowOverwrite:YES];
}

- (BOOL)validateUpdateDownloadedToPath:(NSString *)downloadedPath extractedToPath:(NSString *)extractedPath DSASignature:(NSString *)DSASignature publicDSAKey:(NSString *)publicDSAKey
{
    NSString *newBundlePath = [SUInstaller appPathInUpdateFolder:extractedPath forHost:self.host];
    if (newBundlePath)
    {
        NSError *error = nil;
        if ([SUCodeSigningVerifier codeSignatureIsValidAtPath:newBundlePath error:&error]) {
            return YES;
        } else {
            SULog(@"Code signature check on update failed: %@", error);
        }
    }
    
    return [SUDSAVerifier validatePath:downloadedPath withEncodedDSASignature:DSASignature withPublicDSAKey:publicDSAKey];
}

- (void)downloadDidFinish:(NSURLDownload *)d
{	
	[self extractUpdate];
}

- (void)download:(NSURLDownload *)download didFailWithError:(NSError *)error
{
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while downloading the update. Please try again later.", nil), NSLocalizedDescriptionKey, [error localizedDescription], NSLocalizedFailureReasonErrorKey, nil]]];
}

- (BOOL)download:(NSURLDownload *)download shouldDecodeSourceDataOfMIMEType:(NSString *)encodingType
{
	// We don't want the download system to extract our gzips.
	// Note that we use a substring matching here instead of direct comparison because the docs say "application/gzip" but the system *uses* "application/x-gzip". This is a documentation bug.
	return ([encodingType rangeOfString:@"gzip"].location == NSNotFound);
}

- (void)extractUpdate
{	
	SUUnarchiver *unarchiver = [SUUnarchiver unarchiverForPath:self.downloadPath updatingHost:self.host];
	if (!unarchiver)
	{
		SULog(@"Sparkle Error: No valid unarchiver for %@!", self.downloadPath);
		[self unarchiverDidFail:nil];
		return;
	}
	[unarchiver setDelegate:self];
	[unarchiver start];
}

- (void)failedToApplyDeltaUpdate
{
	// When a delta update fails to apply we fall back on updating via a full install.
	self.updateItem = self.nonDeltaUpdateItem;
	self.nonDeltaUpdateItem = nil;

	[self downloadUpdate];
}

- (void)unarchiverDidFinish:(SUUnarchiver *)ua
{
	[self installWithToolAndRelaunch:YES];
}

- (void)unarchiverDidFail:(SUUnarchiver *)ua
{
	if (self.updateItem.isDeltaUpdate) {
		[self failedToApplyDeltaUpdate];
		return;
	}

	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUUnarchivingError userInfo:[NSDictionary dictionaryWithObject:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil) forKey:NSLocalizedDescriptionKey]]];
}

- (BOOL)shouldInstallSynchronously { return NO; }

- (void)installWithToolAndRelaunch:(BOOL)relaunch
{
#if !ENDANGER_USERS_WITH_INSECURE_UPDATES
    if (![self validateUpdateDownloadedToPath:self.downloadPath extractedToPath:_tempDir DSASignature:self.updateItem.DSASignature publicDSAKey:self.host.publicDSAKey])
    {
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUSignatureError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil), NSLocalizedDescriptionKey, @"The update is improperly signed.", NSLocalizedFailureReasonErrorKey, nil]]];
        return;
	}
#endif
    
    if (![self.updater mayUpdateAndRestart])
    {
        [self abortUpdate];
        return;
    }
	
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
    
    // Give the host app an opportunity to postpone the install and relaunch.
    static BOOL postponedOnce = NO;
    if (!postponedOnce && [delegate respondsToSelector:@selector(updater:shouldPostponeRelaunchForUpdate:untilInvoking:)])
    {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:[[self class] instanceMethodSignatureForSelector:@selector(installWithToolAndRelaunch:)]];
        [invocation setSelector:@selector(installWithToolAndRelaunch:)];
        [invocation setArgument:&relaunch atIndex:2];
        [invocation setTarget:self];
        postponedOnce = YES;
        if ([delegate updater:self.updater shouldPostponeRelaunchForUpdate:self.updateItem untilInvoking:invocation])
            return;
    }

    
	if ([delegate respondsToSelector:@selector(updater:willInstallUpdate:)])
		[delegate updater:self.updater willInstallUpdate:self.updateItem];
	
	// Copy the relauncher into a temporary directory so we can get to it after the new version's installed.
	NSString *relaunchPathToCopy = [SUBundle() pathForResource:@"finish_installation" ofType:@"app"];
    NSString *targetPath = [self.host.appSupportPath stringByAppendingPathComponent:[relaunchPathToCopy lastPathComponent]];
	// Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
	NSError *error = nil;
	[[NSFileManager defaultManager] createDirectoryAtPath: [targetPath stringByDeletingLastPathComponent] withIntermediateDirectories: YES attributes: [NSDictionary dictionary] error: &error];

	// Only the paranoid survive: if there's already a stray copy of relaunch there, we would have problems.
	if( [SUPlainInstaller copyPathWithAuthentication: relaunchPathToCopy overPath: targetPath temporaryName: nil error: &error] )
		_relaunchPath = targetPath;
	else
		[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while extracting the archive. Please try again later.", nil), NSLocalizedDescriptionKey, [NSString stringWithFormat:@"Couldn't copy relauncher (%@) to temporary path (%@)! %@", relaunchPathToCopy, targetPath, (error ? [error localizedDescription] : @"")], NSLocalizedFailureReasonErrorKey, nil]]];
	
    [[NSNotificationCenter defaultCenter] postNotificationName:SUUpdaterWillRestartNotification object:self];
    if ([delegate respondsToSelector:@selector(updaterWillRelaunchApplication:)])
        [delegate updaterWillRelaunchApplication:self.updater];

    if(!_relaunchPath || ![[NSFileManager defaultManager] fileExistsAtPath:_relaunchPath])
    {
        // Note that we explicitly use the host app's name here, since updating plugin for Mail relaunches Mail, not just the plugin.
        [self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SURelaunchError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:SULocalizedString(@"An error occurred while relaunching %1$@, but the new version will be available next time you run %1$@.", nil), self.host.name], NSLocalizedDescriptionKey, [NSString stringWithFormat:@"Couldn't find the relauncher (expected to find it at %@)", _relaunchPath], NSLocalizedFailureReasonErrorKey, nil]]];
        // We intentionally don't abandon the update here so that the host won't initiate another.
        return;
    }		
    
    NSString *pathToRelaunch = self.host.bundlePath;
    if ([delegate respondsToSelector:@selector(pathToRelaunchForUpdater:)])
        pathToRelaunch = [delegate pathToRelaunchForUpdater:self.updater];
    NSString *relaunchToolPath = [_relaunchPath stringByAppendingPathComponent: @"/Contents/MacOS/finish_installation"];
    [NSTask launchedTaskWithLaunchPath: relaunchToolPath arguments:[NSArray arrayWithObjects:self.host.bundlePath, pathToRelaunch, [NSString stringWithFormat:@"%d", [[NSProcessInfo processInfo] processIdentifier]], _tempDir, relaunch ? @"1" : @"0", nil]];

    [NSApp terminate:self];
}

- (void)cleanUpDownload
{
    if (_tempDir != nil)	// tempDir contains downloadPath, so we implicitly delete both here.
	{
		BOOL success = [[NSFileManager defaultManager] removeItemAtPath:_tempDir error: NULL]; // Clean up the copied relauncher
		if( !success )
			[[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:[_tempDir stringByDeletingLastPathComponent] destination:@"" files:[NSArray arrayWithObject:[_tempDir lastPathComponent]] tag:NULL];
	}
}

- (void)installerForHost:(SUHost *)aHost failedWithError:(NSError *)error
{
	if (aHost != self.host) {
		return;
	}
	
	[[NSFileManager defaultManager] removeItemAtPath:_relaunchPath error:NULL];
	[self abortUpdateWithError:[NSError errorWithDomain:SUSparkleErrorDomain code:SUInstallationError userInfo:[NSDictionary dictionaryWithObjectsAndKeys:SULocalizedString(@"An error occurred while installing the update. Please try again later.", nil), NSLocalizedDescriptionKey, [error localizedDescription], NSLocalizedFailureReasonErrorKey, nil]]];
}

- (void)abortUpdate
{
	if (self.download) {
		[self.download cancel];
		self.download = nil;
	}
    [self cleanUpDownload];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[super abortUpdate];
}

- (void)abortUpdateWithError:(NSError *)error
{
	if ([error code] != SUNoUpdateError) // Let's not bother logging this.
		SULog(@"Sparkle Error: %@", [error localizedDescription]);
	if ([error localizedFailureReason])
		SULog(@"Sparkle Error (continued): %@", [error localizedFailureReason]);
	[self abortUpdate];
}


@end
