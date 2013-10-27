//
//  SUInstaller.m
//  Sparkle
//
//  Created by Andy Matuschak on 4/10/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUInstaller.h"
#import "SUPlainInstaller.h"
#import "SUPackageInstaller.h"
#import "SUHost.h"
#import "SUConstants.h"
#import "SULog.h"


@implementation SUInstaller

static NSString*	sUpdateFolder = nil;

+(NSString*)	updateFolder
{
	return sUpdateFolder;
}

static NSURL *sUpdateURL = nil;

+ (NSURL*)updateURL
{
	return sUpdateURL;
}

+ (NSString *)installSourcePathInUpdateFolder:(NSString *)inUpdateFolder forHost:(SUHost *)host isPackage:(BOOL *)isPackagePtr
{
    // Search subdirectories for the application
	NSString	*bundleFileName = host.bundleURL.lastPathComponent,
				*alternateBundleFileName = [host.name stringByAppendingPathExtension:host.bundleURL.pathExtension];
	BOOL isPackage = NO;
	NSURL *inUpdateFolderURL = [NSURL fileURLWithPath:inUpdateFolder isDirectory:YES],
		  *newAppDownloadURL = nil, *fallbackPackageURL = nil;
		
	NSDirectoryEnumerator *dirEnum = [[NSFileManager new] enumeratorAtURL:inUpdateFolderURL includingPropertiesForKeys:@[NSURLIsAliasFileKey] options:0 errorHandler:NULL];
	
	sUpdateFolder = inUpdateFolder;
	sUpdateURL = inUpdateFolderURL;
	
	for (NSURL *currentURL in dirEnum) {
		if ([currentURL.lastPathComponent isEqualToString:bundleFileName] ||
			[currentURL.lastPathComponent isEqualToString:alternateBundleFileName])  // We found one!
		{
			isPackage = NO;
			newAppDownloadURL = currentURL;
			break;
		}
		else if ([currentURL.pathExtension isEqualToString:@"pkg"] ||
				 [currentURL.pathExtension isEqualToString:@"mpkg"])
		{
			if ([[currentURL.lastPathComponent stringByDeletingPathExtension] isEqualToString:[bundleFileName stringByDeletingPathExtension]])
			{
				isPackage = YES;
				newAppDownloadURL = currentURL;
				break;
			}
			else
			{
				// Remember any other non-matching packages we have seen should we need to use one of them as a fallback.
				fallbackPackageURL = currentURL;
			}
			
		}
		else
		{
			// Try matching on bundle identifiers in case the user has changed the name of the host app
			NSBundle *incomingBundle = [NSBundle bundleWithURL:currentURL];
			if(incomingBundle && [incomingBundle.bundleIdentifier isEqualToString:host.bundle.bundleIdentifier])
			{
				isPackage = NO;
				newAppDownloadURL = currentURL;
				break;
			}
		}
		
		// Some DMGs have symlinks into /Applications! That's no good!
		NSNumber *isAlias = nil;
		if ([currentURL getResourceValue:&isAlias forKey:NSURLIsAliasFileKey error:NULL]) {
			if ([isAlias boolValue]) {
				[dirEnum skipDescendents];
			}
		}
	}
	
	// We don't have a valid path. Try to use the fallback package.
	if (newAppDownloadURL == nil && fallbackPackageURL != nil)
	{
		isPackage = YES;
		newAppDownloadURL = fallbackPackageURL;
	}
	
    if (isPackagePtr) *isPackagePtr = isPackage;
    return [newAppDownloadURL path];
}

+ (NSString *)appPathInUpdateFolder:(NSString *)updateFolder forHost:(SUHost *)host
{
    BOOL isPackage = NO;
    NSString *path = [self installSourcePathInUpdateFolder:updateFolder forHost:host isPackage:&isPackage];
    return isPackage ? nil : path;
}

+ (void)installFromUpdateFolder:(NSString *)inUpdateFolder overHost:(SUHost *)host installationPath:(NSString *)installationPath delegate:(id <SUInstallerDelegate>)delegate synchronously:(BOOL)synchronously versionComparator:(id <SUVersionComparison>)comparator
{
    BOOL isPackage = NO;
	NSString *newAppDownloadPath = [self installSourcePathInUpdateFolder:inUpdateFolder forHost:host isPackage:&isPackage];
    
	if (newAppDownloadPath == nil)
	{
		[self finishInstallationToPath:installationPath withResult:NO host:host error:[NSError errorWithDomain:SUSparkleErrorDomain code:SUMissingUpdateError userInfo:[NSDictionary dictionaryWithObject:@"Couldn't find an appropriate update in the downloaded package." forKey:NSLocalizedDescriptionKey]] delegate:delegate];
	}
	else
	{
		[(isPackage ? [SUPackageInstaller class] : [SUPlainInstaller class]) performInstallationToPath:installationPath fromPath:newAppDownloadPath host:host delegate:delegate synchronously:synchronously versionComparator:comparator];
	}
}

+ (void)mdimportInstallationPath:(NSString *)installationPath
{
	// *** GETS CALLED ON NON-MAIN THREAD!
	
	SULog( @"mdimporting" );
	
	NSTask *mdimport = [[NSTask alloc] init];
	[mdimport setLaunchPath:@"/usr/bin/mdimport"];
	[mdimport setArguments:[NSArray arrayWithObject:installationPath]];
	@try
	{
		[mdimport launch];
		[mdimport waitUntilExit];
	}
	@catch (NSException * launchException)
	{
		// No big deal.
		SULog(@"Sparkle Error: %@", [launchException description]);
	}
}

+ (void)finishInstallationToPath:(NSString *)installationPath withResult:(BOOL)result host:(SUHost *)host error:(NSError *)error delegate:(id <SUInstallerDelegate>)delegate
{
	if (result)
	{
		[self mdimportInstallationPath:installationPath];
		if ([delegate respondsToSelector:@selector(installerFinishedForHost:)]) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[delegate installerFinishedForHost:host];
			});
		}
	} else
	{
		if ([delegate respondsToSelector:@selector(installerForHost:failedWithError:)]) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[delegate installerForHost:host failedWithError:error];
			});
		}
	}		
}

@end
