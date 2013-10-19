//
//  SUUnarchiver.m
//  Sparkle
//
//  Created by Andy Matuschak on 3/16/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#import "SUUnarchiver_Private.h"

#import "SUUpdater.h"

#import "SUAppcast.h"
#import "SUAppcastItem.h"
#import "SUVersionComparisonProtocol.h"

@implementation SUUnarchiver

+ (SUUnarchiver *)unarchiverForPath:(NSString *)path updatingHost:(SUHost *)host
{
	NSEnumerator *implementationEnumerator = [[self unarchiverImplementations] objectEnumerator];
	id current;
	while ((current = [implementationEnumerator nextObject]))
	{
		if ([current canUnarchivePath:path])
			return [[current alloc] initWithPath:path host:host];
	}
	return nil;
}

- (NSString *)description { return [NSString stringWithFormat:@"%@ <%@>", [self class], archivePath]; }

- (void)start
{
	// No-op
}

#pragma mark - Private

- (id)initWithPath:(NSString *)path host:(SUHost *)host
{
	if ((self = [super init]))
	{
		archivePath = [path copy];
		updateHost = host;
	}
	return self;
}

+ (BOOL)canUnarchivePath:(NSString *)path
{
	return NO;
}

- (void)notifyDelegateOfExtractedLength:(NSNumber *)length
{
	id <SUUnarchiverDelegate> delegate = self.delegate;
	if ([delegate respondsToSelector:@selector(unarchiver:extractedLength:)])
		[delegate unarchiver:self extractedLength:[length unsignedLongValue]];
}

- (void)notifyDelegateOfSuccess
{
	id <SUUnarchiverDelegate> delegate = self.delegate;
	[delegate unarchiverDidFinish:self];
}

- (void)notifyDelegateOfFailure
{
	id <SUUnarchiverDelegate> delegate = self.delegate;
	[delegate unarchiverDidFail:self];
}

static NSMutableArray *gUnarchiverImplementations;

+ (void)registerImplementation:(Class)implementation
{
	if (!gUnarchiverImplementations)
		gUnarchiverImplementations = [[NSMutableArray alloc] init];
	[gUnarchiverImplementations addObject:implementation];
}

+ (NSArray *)unarchiverImplementations
{
	return [gUnarchiverImplementations copy];
}

@end
