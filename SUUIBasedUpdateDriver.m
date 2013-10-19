//
//  SUUIBasedUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 5/5/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUUIBasedUpdateDriver.h"
#import "SUUpdateAlert.h"
#import "SUUpdater_Private.h"
#import "SUHost.h"
#import "SUStatusController.h"
#import "SUConstants.h"
#import "SUPasswordPrompt.h"

@interface SUUIBasedUpdateDriver ()

@property (nonatomic, strong) SUStatusController *statusController;
@property (nonatomic, strong) SUUpdateAlert *updateAlert;

@end

@implementation SUUIBasedUpdateDriver

- (void)didFindValidUpdate
{
	self.updateAlert = [[SUUpdateAlert alloc] initWithAppcastItem:self.updateItem host:self.host completion:^(SUUpdateAlertChoice choice) {
		self.updateAlert = nil;
		[self.host setObject:nil forUserDefaultsKey:SUSkippedVersionKey];
		switch (choice)
		{
			case SUInstallUpdateChoice: {
				SUStatusController *statusController = [[SUStatusController alloc] initWithHost:self.host];
				[statusController beginActionWithTitle:SULocalizedString(@"Downloading update...", @"Take care not to overflow the status window.") maxProgressValue:0.0 statusText:nil];
				[statusController setButtonTitle:SULocalizedString(@"Cancel", nil) target:self action:@selector(cancelDownload:) isDefault:NO];
				[statusController showWindow:self];
				self.statusController = statusController;
				[self downloadUpdate];
				break;
			}
				
			case SUOpenInfoURLChoice:
				[[NSWorkspace sharedWorkspace] openURL:self.updateItem.infoURL];
				[self abortUpdate];
				break;
				
			case SUSkipThisVersionChoice:
				[self.host setObject:self.updateItem.versionString forUserDefaultsKey:SUSkippedVersionKey];
				[self abortUpdate];
				break;
				
			case SURemindMeLaterChoice:
				[self abortUpdate];
				break;			
		}
	}];
	
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	
	id<SUVersionDisplay>	versDisp = nil;
	if ([delegate respondsToSelector:@selector(versionDisplayerForUpdater:)])
		versDisp = [delegate versionDisplayerForUpdater:self.updater];
	[self.updateAlert setVersionDisplayer: versDisp];
	
	if ([delegate respondsToSelector:@selector(updater:didFindValidUpdate:)])
		[delegate updater:self.updater didFindValidUpdate:self.updateItem];

	// If the app is a menubar app or the like, we need to focus it first and alter the
	// update prompt to behave like a normal window. Otherwise if the window were hidden
	// there may be no way for the application to be activated to make it visible again.
	if ([self.host isBackgroundApplication])
	{
		[self.updateAlert.window setHidesOnDeactivate:NO];
		[NSApp activateIgnoringOtherApps:YES];
	}
	
	// Only show the update alert if the app is active; otherwise, we'll wait until it is.
	if ([NSApp isActive]) {
		[self.updateAlert.window makeKeyAndOrderFront:self];
	} else {
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];
	}
}

- (void)didNotFindUpdate
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	if ([delegate respondsToSelector:@selector(updaterDidNotFindUpdate:)])
		[delegate updaterDidNotFindUpdate:self.updater];
	
	NSAlert *alert = [NSAlert alertWithMessageText:SULocalizedString(@"You're up-to-date!", nil) defaultButton:SULocalizedString(@"OK", nil) alternateButton:nil otherButton:nil informativeTextWithFormat:SULocalizedString(@"%@ %@ is currently the newest version available.", nil), self.host.name, self.host.displayVersion];
	[self showModalAlert:alert];
	[self abortUpdate];
}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification
{
	[self.updateAlert.window makeKeyAndOrderFront:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:@"NSApplicationDidBecomeActiveNotification" object:NSApp];
}

- (void)download:(NSURLDownload *)download didReceiveResponse:(NSURLResponse *)response
{
	self.statusController.maxProgressValue = response.expectedContentLength;
}

- (NSString *)humanReadableSizeFromDouble:(double)value
{
	if (value < 1000)
		return [NSString stringWithFormat:@"%.0lf %@", value, SULocalizedString(@"B", @"the unit for bytes")];
	
	if (value < 1000 * 1000)
		return [NSString stringWithFormat:@"%.0lf %@", value / 1000.0, SULocalizedString(@"KB", @"the unit for kilobytes")];
	
	if (value < 1000 * 1000 * 1000)
		return [NSString stringWithFormat:@"%.1lf %@", value / 1000.0 / 1000.0, SULocalizedString(@"MB", @"the unit for megabytes")];
	
	return [NSString stringWithFormat:@"%.2lf %@", value / 1000.0 / 1000.0 / 1000.0, SULocalizedString(@"GB", @"the unit for gigabytes")];	
}

- (void)download:(NSURLDownload *)download didReceiveDataOfLength:(NSUInteger)length
{
	self.statusController.progressValue += length;
	if (self.statusController.maxProgressValue > 0.0) {
		self.statusController.statusText = [NSString stringWithFormat:SULocalizedString(@"%@ of %@", nil), [self humanReadableSizeFromDouble:self.statusController.progressValue], [self humanReadableSizeFromDouble:self.statusController.maxProgressValue]];
	} else {
		self.statusController.statusText = [NSString stringWithFormat:SULocalizedString(@"%@ downloaded", nil), [self humanReadableSizeFromDouble:self.statusController.progressValue]];
	}
}

- (IBAction)cancelDownload: (id)sender
{
	[self abortUpdate];
}

- (void)extractUpdate
{
	// Now we have to extract the downloaded archive.
	[self.statusController beginActionWithTitle:SULocalizedString(@"Extracting update...", @"Take care not to overflow the status window.") maxProgressValue:0.0 statusText:nil];
	[self.statusController setButtonEnabled:NO];
	[super extractUpdate];
}

- (void)unarchiver:(SUUnarchiver *)ua extractedLength:(unsigned long)length
{
	// We do this here instead of in extractUpdate so that we only have a determinate progress bar for archives with progress.
	if (self.statusController.maxProgressValue == 0.0)
	{
		NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:self.downloadPath error:NULL];
		self.statusController.maxProgressValue = [attributes[NSFileSize] doubleValue];
	}
	self.statusController.progressValue += length;
}

- (void)unarchiverDidFinish:(SUUnarchiver *)ua
{
	[self.statusController beginActionWithTitle:SULocalizedString(@"Ready to Install", nil) maxProgressValue:1.0 statusText:nil];
	self.statusController.progressValue = 1.0;
	[self.statusController setButtonEnabled:YES];
	[self.statusController setButtonTitle:SULocalizedString(@"Install and Relaunch", nil) target:self action:@selector(installAndRestart:) isDefault:YES];
	[self.statusController.window makeKeyAndOrderFront: self];
	[NSApp requestUserAttention:NSInformationalRequest];	
}

- (void)unarchiver:(SUUnarchiver *)unarchiver requiresPasswordWithCompletion:(void(^)(NSString *password))completionBlock
{
    SUPasswordPrompt *prompt = [[SUPasswordPrompt alloc] initWithHost:self.host];
    NSString *password = nil;
    if([prompt run])
    {
        password = [prompt password];
    }
	completionBlock(password);
}

- (void)installAndRestart: (id)sender
{
    [self installWithToolAndRelaunch:YES];
}

- (void)installWithToolAndRelaunch:(BOOL)relaunch
{
	[self.statusController beginActionWithTitle:SULocalizedString(@"Installing update...", @"Take care not to overflow the status window.") maxProgressValue:0.0 statusText:nil];
	[self.statusController setButtonEnabled:NO];
	[super installWithToolAndRelaunch:relaunch];
	
	
	// if a user chooses to NOT relaunch the app (as is the case with WebKit
	// when it asks you if you are sure you want to close the app with multiple
	// tabs open), the status window still stays on the screen and obscures
	// other windows; with this fix, it doesn't
	
	if (self.statusController)
	{
		[self.statusController close];
		self.statusController = nil;
	}
}

- (void)abortUpdateWithError:(NSError *)error
{
	NSAlert *alert = [NSAlert alertWithMessageText:SULocalizedString(@"Update Error!", nil) defaultButton:SULocalizedString(@"Cancel Update", nil) alternateButton:nil otherButton:nil informativeTextWithFormat:@"%@", [error localizedDescription]];
	[self showModalAlert:alert];
	[super abortUpdateWithError:error];
}

- (void)abortUpdate
{
	if (self.statusController)
	{
		[self.statusController close];
		self.statusController = nil;
	}
	[super abortUpdate];
}

- (void)showModalAlert:(NSAlert *)alert
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	
	if ([delegate respondsToSelector:@selector(updaterWillShowModalAlert:)])
		[delegate updaterWillShowModalAlert:self.updater];

	// When showing a modal alert we need to ensure that background applications
	// are focused to inform the user since there is no dock icon to notify them.
	if ([self.host isBackgroundApplication]) { [NSApp activateIgnoringOtherApps:YES]; }
	
	[alert setIcon:[self.host icon]];
	[alert runModal];
	
	if ([delegate respondsToSelector:@selector(updaterDidShowModalAlert:)])
		[delegate updaterDidShowModalAlert:self.updater];
}

@end
