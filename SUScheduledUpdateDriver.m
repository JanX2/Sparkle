//
//  SUScheduledUpdateDriver.m
//  Sparkle
//
//  Created by Andy Matuschak on 5/6/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUScheduledUpdateDriver.h"
#import "SUUpdater.h"

#import "SUAppcast.h"
#import "SUAppcastItem.h"
#import "SUVersionComparisonProtocol.h"

@interface SUScheduledUpdateDriver () {
	BOOL _showErrors;
}

@end

@implementation SUScheduledUpdateDriver

- (void)didFindValidUpdate
{
	_showErrors = YES; // We only start showing errors after we present the UI for the first time.
	[super didFindValidUpdate];
}

- (void)didNotFindUpdate
{
	id <SUUpdaterDelegate> delegate = self.updater.delegate;
	if ([delegate respondsToSelector:@selector(updaterDidNotFindUpdate:)])
		[delegate updaterDidNotFindUpdate:self.updater];
	[self abortUpdate]; // Don't tell the user that no update was found; this was a scheduled update.
}

- (void)abortUpdateWithError:(NSError *)error
{
	if (_showErrors)
		[super abortUpdateWithError:error];
	else
		[self abortUpdate];
}

@end
