//
//  SUDiskImageUnarchiver.m
//  Sparkle
//
//  Created by Andy Matuschak on 6/16/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUDiskImageUnarchiver.h"
#import "SUUnarchiver_Private.h"
#import "NTSynchronousTask.h"
#import "SULog.h"
#import <CoreServices/CoreServices.h>

@implementation SUDiskImageUnarchiver

+ (BOOL)canUnarchivePath:(NSString *)path
{
	return [[path pathExtension] isEqualToString:@"dmg"];
}

// Called on a non-main thread.
- (void)extractDMG
{
	@autoreleasepool {
    
        NSData *result = [NTSynchronousTask task:@"/usr/bin/hdiutil" directory:@"/" withArgs:[NSArray arrayWithObjects: @"isencrypted", self.archivePath, nil] input:NULL];
		
		id <SUUnarchiverDelegate> delegate = self.delegate;
		if ([[self class] isEncrypted:result] && [delegate respondsToSelector:@selector(unarchiver:requiresPasswordWithCompletion:)]) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[delegate unarchiver:self requiresPasswordWithCompletion:^(NSString *password) {
					dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
						[self extractDMGWithPassword:password];
					});
				}];
			});
        } else {
            [self extractDMGWithPassword:nil];
        }
    
    }
}

// Called on a non-main thread.
- (void)extractDMGWithPassword:(NSString *)password
{
    @autoreleasepool {
        __block BOOL mountedSuccessfully = NO;
		__block NSString *mountPoint = nil;

		void (^cleanup)(void) = ^{
			if (mountedSuccessfully)
				[NSTask launchedTaskWithLaunchPath:@"/usr/bin/hdiutil" arguments:[NSArray arrayWithObjects:@"detach", mountPoint, @"-force", nil]];
			else
				SULog(@"Can't mount DMG %@", self.archivePath);
		};
		
		void (^reportError)(void) = ^{
			
			dispatch_async(dispatch_get_main_queue(), ^{
				[self notifyDelegateOfFailure];
			});
			
			cleanup();
		};
		

        SULog(@"Extracting %@ as a DMG", self.archivePath);

        // get a unique mount point path
        FSRef tmpRef;
        do {
            CFUUIDRef uuid = CFUUIDCreate(NULL);
            if (uuid) {
                CFStringRef uuidString = CFUUIDCreateString(NULL, uuid);
                if (uuidString) {
                    mountPoint = [@"/Volumes" stringByAppendingPathComponent:(__bridge NSString *) uuidString];
                    CFRelease(uuidString);
                }
                CFRelease(uuid);
            }
        }
        while (noErr == FSPathMakeRefWithOptions((UInt8 *) [mountPoint fileSystemRepresentation], kFSPathMakeRefDoNotFollowLeafSymlink, &tmpRef, NULL));

        NSData *promptData = nil;
        if (password) {
            NSString *data = [NSString stringWithFormat:@"%@\nyes\n", password];
            const char *bytes = [data cStringUsingEncoding:NSUTF8StringEncoding];
            NSUInteger length = [data lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            promptData = [NSData dataWithBytes:bytes length:length];
        }
        else
            promptData = [NSData dataWithBytes:"yes\n" length:4];

        NSArray *arguments = [NSArray arrayWithObjects:@"attach", self.archivePath, @"-mountpoint", mountPoint, /*@"-noverify",*/ @"-nobrowse", @"-noautoopen", nil];

        NSData *output = nil;
        NSInteger taskResult = -1;
        @try {
            NTSynchronousTask *task = [[NTSynchronousTask alloc] init];

            [task run:@"/usr/bin/hdiutil" directory:@"/" withArgs:arguments input:promptData];

            taskResult = [task result];
            output = [[task output] copy];
        }
        @catch (NSException *localException) {
            reportError();
			return;
        }

        if (taskResult != 0) {
            NSString *resultStr = output ? [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] : nil;
			id <SUUnarchiverDelegate> delegate = self.delegate;
            if (password != nil && [resultStr rangeOfString:@"Authentication error"].location != NSNotFound && [delegate respondsToSelector:@selector(unarchiver:requiresPasswordWithCompletion:)]) {
				dispatch_async(dispatch_get_main_queue(), ^{
					[delegate unarchiver:self requiresPasswordWithCompletion:^(NSString *retPassword) {
						dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
							[self extractDMGWithPassword:retPassword];
						});
					}];
				});
				cleanup();
            } else {
                SULog(@"hdiutil failed with code: %d data: <<%@>>", taskResult, resultStr);
                reportError();
            }
			return;
        }
		
        mountedSuccessfully = YES;

		NSFileManager *manager = [[NSFileManager alloc] init];
		NSError *error = nil;
		NSArray *contents = [manager contentsOfDirectoryAtPath:mountPoint error:&error];
		if (error) {
			SULog(@"Couldn't enumerate contents of archive mounted at %@: %@", mountPoint, error);
			reportError();
			return;
		}
		
		NSEnumerator *contentsEnumerator = [contents objectEnumerator];
		NSString *item;
		while ((item = [contentsEnumerator nextObject])) {
			NSString *fromPath = [mountPoint stringByAppendingPathComponent:item];
			NSString *toPath = [[self.archivePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:item];
			
			// We skip any files in the DMG which are not readable.
			if (![manager isReadableFileAtPath:fromPath])
				continue;
			
			SULog(@"copyItemAtPath:%@ toPath:%@", fromPath, toPath);
			
			if (![manager copyItemAtPath:fromPath toPath:toPath error:&error]) {
				SULog(@"Couldn't copy item: %@ : %@", error, error.userInfo ? error.userInfo : @"");
				reportError();
				return;
			}
		}
		
		dispatch_async(dispatch_get_main_queue(), ^{
			[self notifyDelegateOfSuccess];
		});
		
		cleanup();
    }
}

- (void)start
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		[self extractDMG];
	});
}

+ (void)load
{
	[self registerImplementation:self];
}

+ (BOOL)isEncrypted:(NSData*)resultData
{
	if (!resultData) {
		return NO;
	}
	
	NSString *data = [[NSString alloc] initWithBytesNoCopy:(char *)[resultData bytes] length:(char *)[resultData length] encoding:NSUTF8StringEncoding freeWhenDone:NO];
	if (!NSEqualRanges([data rangeOfString:@"passphrase-count"], NSMakeRange(NSNotFound, 0)))
	{
		return YES;
	}
	
	return NO;
}

@end
