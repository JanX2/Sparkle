//
//  SUBasicUpdateDriver.h
//  Sparkle,
//
//  Created by Andy Matuschak on 4/23/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#ifndef SUBASICUPDATEDRIVER_H
#define SUBASICUPDATEDRIVER_H

#import <Cocoa/Cocoa.h>
#import "SUUpdateDriver.h"
#import "SUAppcast.h"
#import "SUUnarchiver.h"

@class SUAppcastItem, SUAppcast, SUUnarchiver, SUHost;

@interface SUBasicUpdateDriver : SUUpdateDriver <SUAppcastDelegate, NSURLDownloadDelegate>

- (BOOL)isItemNewer:(SUAppcastItem *)ui;
- (BOOL)hostSupportsItem:(SUAppcastItem *)ui;
- (BOOL)itemContainsSkippedVersion:(SUAppcastItem *)ui;
- (BOOL)itemContainsValidUpdate:(SUAppcastItem *)ui;
- (void)didFindValidUpdate;
- (void)didNotFindUpdate;

- (void)downloadUpdate;

- (void)extractUpdate;
- (void)failedToApplyDeltaUpdate;

- (void)installWithToolAndRelaunch:(BOOL)relaunch;
- (void)installerForHost:(SUHost *)host failedWithError:(NSError *)error;

- (void)installWithToolAndRelaunch:(BOOL)relaunch;
- (void)cleanUpDownload;

- (void)abortUpdateWithError:(NSError *)error;

@property (nonatomic, strong, readonly) SUAppcastItem *updateItem;
@property (nonatomic, strong, readonly) NSURLDownload *download;
@property (nonatomic, strong, readonly) NSString *downloadPath;

@end

#endif
