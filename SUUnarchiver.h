//
//  SUUnarchiver.h
//  Sparkle
//
//  Created by Andy Matuschak on 3/16/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#ifndef SUUNARCHIVER_H
#define SUUNARCHIVER_H

@class SUUnarchiver, SUHost;

@protocol SUUnarchiverDelegate <NSObject>

- (void)unarchiverDidFinish:(SUUnarchiver *)unarchiver;
- (void)unarchiverDidFail:(SUUnarchiver *)unarchiver;

@optional

- (void)unarchiver:(SUUnarchiver *)unarchiver extractedLength:(unsigned long)length;
- (void)unarchiver:(SUUnarchiver *)unarchiver requiresPasswordWithCompletion:(void(^)(NSString *password))completionBlock;

@end

@interface SUUnarchiver : NSObject {
	NSString *archivePath;
	SUHost *updateHost;
}

+ (SUUnarchiver *)unarchiverForPath:(NSString *)path updatingHost:(SUHost *)host;

@property (nonatomic, weak) id <SUUnarchiverDelegate> delegate;

- (void)start;

@end

#endif
