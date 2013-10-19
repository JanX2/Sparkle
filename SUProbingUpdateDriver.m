//
//  SUProbingUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 5/7/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUProbingUpdateDriver.h"
#import "SUUpdater.h"

@implementation SUProbingUpdateDriver

// Stop as soon as we have an answer! Since the superclass implementations are not called, we are responsible for notifying the delegate.

- (void)didFindValidUpdate
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	if ([delegate respondsToSelector:@selector(updater:didFindValidUpdate:)])
		[delegate updater:self.updater didFindValidUpdate:self.updateItem];
	[self abortUpdate];
}

- (void)didNotFindUpdate
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	if ([delegate respondsToSelector:@selector(updaterDidNotFindUpdate:)])
		[delegate updaterDidNotFindUpdate:self.updater];
	[self abortUpdate];
}

@end
