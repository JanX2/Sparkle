//
//  SUUpdateAlert.h
//  Sparkle
//
//  Created by Andy Matuschak on 3/12/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#ifndef SUUPDATEALERT_H
#define SUUPDATEALERT_H

#import "SUWindowController.h"
#import "SUVersionDisplayProtocol.h"

typedef enum {
	SUInstallUpdateChoice,
	SURemindMeLaterChoice,
	SUSkipThisVersionChoice,
	SUOpenInfoURLChoice
} SUUpdateAlertChoice;

@class WebView, SUAppcastItem, SUHost;

@interface SUUpdateAlert : SUWindowController

- (id)initWithAppcastItem:(SUAppcastItem *)item host:(SUHost *)host completion:(void(^)(SUUpdateAlertChoice))block;

- (IBAction)installUpdate:sender;
- (IBAction)skipThisVersion:sender;
- (IBAction)remindMeLater:sender;

- (void)setVersionDisplayer: (id<SUVersionDisplay>)disp;

@end

#endif
