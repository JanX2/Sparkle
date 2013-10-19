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

@interface SUUnarchiver ()


@property (nonatomic, copy, readwrite) NSString *archivePath;
@property (nonatomic, strong, readwrite) SUHost *updateHost;

@end

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

- (NSString *)description {
	return [NSString stringWithFormat:@"%@ <%@>", [self class], self.archivePath];
}

- (void)start
{
	// No-op
}

#pragma mark - Private

- (id)initWithPath:(NSString *)path host:(SUHost *)host
{
	if ((self = [super init]))
	{
		self.archivePath = path;
		self.updateHost = host;
	}
	return self;
}

+ (BOOL)canUnarchivePath:(NSString *)path
{
	return NO;
}

- (void)notifyDelegateOfExtractedLength:(unsigned long)length
{
	id <SUUnarchiverDelegate> delegate = self.delegate;
	if ([delegate respondsToSelector:@selector(unarchiver:extractedLength:)])
		[delegate unarchiver:self extractedLength:length];
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
