//
//  SUUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 5/7/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUUpdateDriver.h"
#import "SUHost.h"

NSString * const SUUpdateDriverFinishedNotification = @"SUUpdateDriverFinished";

@implementation SUUpdateDriver

- (instancetype)initWithUpdater:(SUUpdater *)anUpdater
{
	self = [super init];
	if (self) {
		_updater = anUpdater;
	}
	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"%@ <%@, %@>", [self class], self.host.bundlePath, self.host.installationPath];
}

- (void)checkForUpdatesAtURL:(NSURL *)URL host:(SUHost *)host
{
	_appcastURL = [URL copy];
	_host = host;
}

- (void)abortUpdate
{
	_finished = YES;
	[[NSNotificationCenter defaultCenter] postNotificationName:SUUpdateDriverFinishedNotification object:self];
}

@end
