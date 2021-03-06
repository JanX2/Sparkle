//
//  SUUpdatePermissionPrompt.h
//  Sparkle
//
//  Created by Andy Matuschak on 1/24/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#ifndef SUUPDATEPERMISSIONPROMPT_H
#define SUUPDATEPERMISSIONPROMPT_H

#import "SUWindowController.h"

typedef enum {
	SUAutomaticallyCheck,
	SUDoNotAutomaticallyCheck
} SUPermissionPromptResult;

@class SUHost, SUUpdatePermissionPrompt;

@interface SUUpdatePermissionPrompt : SUWindowController

+ (void)promptWithHost:(SUHost *)aHost systemProfile:(NSArray *)profile completion:(void(^)(SUPermissionPromptResult))block;
- (IBAction)toggleMoreInfo:(id)sender;
- (IBAction)finishPrompt:(id)sender;

@end

#endif
