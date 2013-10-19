//
//  SUUpdateDriver.h
//  Sparkle
//
//  Created by Andy Matuschak on 5/7/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#ifndef SUUPDATEDRIVER_H
#define SUUPDATEDRIVER_H

#import <Cocoa/Cocoa.h>

extern NSString *const SUUpdateDriverFinishedNotification;

@class SUHost, SUUpdater;

@interface SUUpdateDriver : NSObject

- (instancetype)initWithUpdater:(SUUpdater *)updater;
- (void)checkForUpdatesAtURL:(NSURL *)URL host:(SUHost *)host SU_REQUIRES_SUPER;
- (void)abortUpdate;

@property (nonatomic, strong, readonly) SUUpdater *updater;
@property (nonatomic, strong, readonly) SUHost *host;
@property (nonatomic, copy, readonly) NSURL *appcastURL;
@property (nonatomic, readonly, getter = isFinished) BOOL finished;

@end

#endif
