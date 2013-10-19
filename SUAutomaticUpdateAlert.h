//
//  SUAutomaticUpdateAlert.h
//  Sparkle
//
//  Created by Andy Matuschak on 3/18/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#ifndef SUAUTOMATICUPDATEALERT_H
#define SUAUTOMATICUPDATEALERT_H

#import "SUWindowController.h"

typedef enum {
	SUInstallNowChoice,
	SUInstallLaterChoice,
	SUDoNotInstallChoice
} SUAutomaticInstallationChoice;

@class SUAppcastItem, SUHost;

@interface SUAutomaticUpdateAlert : SUWindowController

- (id)initWithAppcastItem:(SUAppcastItem *)item host:(SUHost *)host completion:(void(^)(SUAutomaticInstallationChoice))block;
- (IBAction)installNow:sender;
- (IBAction)installLater:sender;
- (IBAction)doNotInstall:sender;

@end

#endif
