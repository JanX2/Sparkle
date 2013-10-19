//
//  SUUserInitiatedUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 5/30/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUUserInitiatedUpdateDriver.h"

#import "SUStatusController.h"
#import "SUHost.h"

@interface SUUserInitiatedUpdateDriver () {
	BOOL _isCanceled;
}

@property (nonatomic, strong) SUStatusController *checkingController;

@end

@implementation SUUserInitiatedUpdateDriver

- (void)closeCheckingWindow
{
	if (self.checkingController)
	{
		[self.checkingController.window close];
		self.checkingController = nil;
	}
}

- (void)cancelCheckForUpdates:sender
{
	[self closeCheckingWindow];
	_isCanceled = YES;
}

- (void)checkForUpdatesAtURL:(NSURL *)URL host:(SUHost *)aHost
{
	SUStatusController *checkingController = [[SUStatusController alloc] initWithHost:aHost];
	[[checkingController window] center]; // Force the checking controller to load its window.
	[checkingController beginActionWithTitle:SULocalizedString(@"Checking for updates...", nil) maxProgressValue:0.0 statusText:nil];
	[checkingController setButtonTitle:SULocalizedString(@"Cancel", nil) target:self action:@selector(cancelCheckForUpdates:) isDefault:NO];
	[checkingController showWindow:self];
	self.checkingController = checkingController;
	[super checkForUpdatesAtURL:URL host:aHost];
	
	// For background applications, obtain focus.
	// Useful if the update check is requested from another app like System Preferences.
	if ([aHost isBackgroundApplication])
	{
		[NSApp activateIgnoringOtherApps:YES];
	}
}

- (void)appcastDidFinishLoading:(SUAppcast *)ac
{
	if (_isCanceled)
	{
		[self abortUpdate];
		return;
	}
	[self closeCheckingWindow];
	[super appcastDidFinishLoading:ac];
}

- (void)abortUpdateWithError:(NSError *)error
{
	[self closeCheckingWindow];
	[super abortUpdateWithError:error];
}

- (void)abortUpdate
{
	[self closeCheckingWindow];
	[super abortUpdate];
}

- (void)appcast:(SUAppcast *)ac failedToLoadWithError:(NSError *)error
{
	if (_isCanceled)
	{
		[self abortUpdate];
		return;
	}
	[super appcast:ac failedToLoadWithError:error];
}

- (BOOL)itemContainsValidUpdate:(SUAppcastItem *)ui
{
	// We don't check to see if this update's been skipped, because the user explicitly *asked* if he had the latest version.
	return [self hostSupportsItem:ui] && [self isItemNewer:ui];
}

@end
