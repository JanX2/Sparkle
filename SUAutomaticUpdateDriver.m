//
//  SUAutomaticUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 5/6/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUAutomaticUpdateDriver.h"
#import "SUAutomaticUpdateAlert.h"
#import "SUHost.h"

@interface SUAutomaticUpdateDriver () {
	BOOL _postponingInstallation, _showErrors;
}
@property (nonatomic, strong) SUAutomaticUpdateAlert *alert;

@end

@implementation SUAutomaticUpdateDriver

- (void)unarchiverDidFinish:(SUUnarchiver *)ua
{
	self.alert = [[SUAutomaticUpdateAlert alloc] initWithAppcastItem:self.updateItem host:self.host completion:^(SUAutomaticInstallationChoice choice) {
		switch (choice)
		{
			case SUInstallNowChoice:
				[self installWithToolAndRelaunch:YES];
				break;
				
			case SUInstallLaterChoice:
				_postponingInstallation = YES;
				[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillTerminate:) name:NSApplicationWillTerminateNotification object:nil];
				break;
				
			case SUDoNotInstallChoice:
				[self.host setObject:self.updateItem.versionString forUserDefaultsKey:SUSkippedVersionKey];
				[self abortUpdate];
				break;
		}
	}];
	
	// If the app is a menubar app or the like, we need to focus it first and alter the
	// update prompt to behave like a normal window. Otherwise if the window were hidden
	// there may be no way for the application to be activated to make it visible again.
	if ([self.host isBackgroundApplication])
	{
		[self.alert.window setHidesOnDeactivate:NO];
		[NSApp activateIgnoringOtherApps:YES];
	}		
	
	if ([NSApp isActive])
		[self.alert.window makeKeyAndOrderFront:self];
	else
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:NSApplicationDidBecomeActiveNotification object:NSApp];	
}

- (void)applicationDidBecomeActive:(NSNotification *)aNotification
{
	[self.alert.window makeKeyAndOrderFront:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:NSApp];
}

- (BOOL)shouldInstallSynchronously { return _postponingInstallation; }

- (void)installWithToolAndRelaunch:(BOOL)relaunch
{
	_showErrors = YES;
	[super installWithToolAndRelaunch:relaunch];
}

- (void)applicationWillTerminate:(NSNotification *)note
{
	[self installWithToolAndRelaunch:NO];
}

- (void)abortUpdateWithError:(NSError *)error
{
	if (_showErrors)
		[super abortUpdateWithError:error];
	else
		[self abortUpdate];
}

@end
