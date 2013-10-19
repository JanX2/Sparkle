//
//  NTSynchronousTask.m
//  CocoatechCore
//
//  Created by Steve Gehrman on 9/29/05.
//  Copyright 2005 Steve Gehrman. All rights reserved.
//

#import "SUUpdater.h"

#import "SUAppcast.h"
#import "SUAppcastItem.h"
#import "SUVersionComparisonProtocol.h"
#import "NTSynchronousTask.h"

@interface NTSynchronousTask ()

@property (nonatomic, strong) NSTask *task;
@property (nonatomic, strong) NSPipe *outputPipe;
@property (nonatomic, strong) NSPipe *inputPipe;
@property (nonatomic, strong) NSData *output;
@property (nonatomic) BOOL done;
@property (nonatomic) int result;

@end

@implementation NTSynchronousTask

@synthesize task = mv_task;
@synthesize outputPipe = mv_outputPipe;
@synthesize inputPipe = mv_inputPipe;
@synthesize output = mv_output;
@synthesize done = mv_done;
@synthesize result = mv_result;


- (void)taskOutputAvailable:(NSNotification*)note
{
	[self setOutput:[[note userInfo] objectForKey:NSFileHandleNotificationDataItem]];
	
	[self setDone:YES];
}

- (void)taskDidTerminate:(NSNotification*)note
{
    [self setResult:[[self task] terminationStatus]];
}

- (id)init;
{
    self = [super init];
	if (self)
	{
		self.task = [NSTask new];
		self.outputPipe = [NSPipe new];
		self.inputPipe = [NSPipe new];
		
		[[self task] setStandardInput:[self inputPipe]];
		[[self task] setStandardOutput:[self outputPipe]];
		[[self task] setStandardError:[self outputPipe]];
	}
	
    return self;
}

//---------------------------------------------------------- 
// dealloc
//---------------------------------------------------------- 
- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)run:(NSString*)toolPath directory:(NSString*)currentDirectory withArgs:(NSArray*)args input:(NSData*)input
{
	BOOL success = NO;
	
	if (currentDirectory)
		[[self task] setCurrentDirectoryPath: currentDirectory];
	
	[[self task] setLaunchPath:toolPath];
	[[self task] setArguments:args];
				
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(taskOutputAvailable:)
												 name:NSFileHandleReadToEndOfFileCompletionNotification
											   object:[[self outputPipe] fileHandleForReading]];
		
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(taskDidTerminate:)
												 name:NSTaskDidTerminateNotification
											   object:[self task]];	
	
	[[[self outputPipe] fileHandleForReading] readToEndOfFileInBackgroundAndNotifyForModes:[NSArray arrayWithObjects:NSDefaultRunLoopMode, NSModalPanelRunLoopMode, NSEventTrackingRunLoopMode, nil]];
	
	@try
	{
		[[self task] launch];
		success = YES;
	}
	@catch (NSException *localException) { }
	
	if (success)
	{
		if (input)
		{
			// feed the running task our input
			[[[self inputPipe] fileHandleForWriting] writeData:input];
			[[[self inputPipe] fileHandleForWriting] closeFile];
		}
						
		// loop until we are done receiving the data
		if (![self done])
		{
			double resolution = 1;
			BOOL isRunning;
			NSDate* next;
			
			do {
				next = [NSDate dateWithTimeIntervalSinceNow:resolution]; 
				
				isRunning = [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
													 beforeDate:next];
			} while (isRunning && ![self done]);
		}
	}
}

+ (NSData*)task:(NSString*)toolPath directory:(NSString*)currentDirectory withArgs:(NSArray*)args input:(NSData*)input
{
	// we need this wacky pool here, otherwise we run out of pipes, the pipes are internally autoreleased
	NSData *result = nil;
	
	@autoreleasepool {
		@try
		{
			NTSynchronousTask* task = [[NTSynchronousTask alloc] init];
			
			[task run:toolPath directory:currentDirectory withArgs:args input:input];
			
			if ([task result] == 0)
				result = [task output];
		}
		@catch (NSException *localException) { }
	}
	
    return result;
}


+(int)	task:(NSString*)toolPath directory:(NSString*)currentDirectory withArgs:(NSArray*)args input:(NSData*)input output:(NSData**)outData
{
	int taskResult = 0;
	NSData *data = nil;
	
	if (outData)
		*outData = nil;
	
	@autoreleasepool {
		@try {
			NTSynchronousTask* task = [[NTSynchronousTask alloc] init];
			
			[task run:toolPath directory:currentDirectory withArgs:args input:input];
			
			taskResult = [task result];
			data = [task output];
		}
		@catch (NSException *exception) {
			taskResult = errCppGeneral;
		}
	}
	
	if (outData) {
		*outData = data;
	}
	
	return taskResult;
}

@end
