//
//  SUPipedUnarchiver.m
//  Sparkle
//
//  Created by Andy Matuschak on 6/16/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUPipedUnarchiver.h"
#import "SUUnarchiver_Private.h"
#import "SULog.h"

@implementation SUPipedUnarchiver

+ (NSString *)commandConformingToTypeOfPath:(NSString *)path
{
	NSString *extractZIP = @"ditto -x -k - \"$DESTINATION\"";
	NSString *extractTAR = @"tar -xC \"$DESTINATION\"";
	NSString *extractTBZ = @"tar -jxC \"$DESTINATION\"";
	NSString *extractTGZ = @"tar -zxC \"$DESTINATION\"";
	
	NSDictionary *typeSelectorDictionary = @{
											 @".zip": extractZIP,
											 @".tar": extractTAR,
											 @".tar.gz": extractTGZ,
											 @".tgz": extractTGZ,
											 @".tar.bz2": extractTBZ,
											 @".tbz": extractTBZ
											 };
	
	NSString *lastPathComponent = [path lastPathComponent];
	__block NSString *ret = NULL;
	[typeSelectorDictionary enumerateKeysAndObjectsUsingBlock:^(NSString *currentType, dispatch_block_t obj, BOOL *stop) {
		if ([currentType length] > [lastPathComponent length]) return;
		if ([[lastPathComponent substringFromIndex:[lastPathComponent length] - [currentType length]] isEqualToString:currentType]) {
			ret = obj;
			*stop = YES;
		}
	}];
	return ret;
}

- (dispatch_block_t)extractorConformingToTypeOfPath:(NSString *)path
{
	NSString *command = [[self class] commandConformingToTypeOfPath:path];
	if (!command) return NULL;
	return  ^{
		[self extractArchivePipingDataToCommand:command];
	};
}

- (void)start
{
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), [self extractorConformingToTypeOfPath:archivePath]);
}

+ (BOOL)canUnarchivePath:(NSString *)path
{
	return ([self commandConformingToTypeOfPath:path] != nil);
}

// This method abstracts the types that use a command line tool piping data from stdin.
- (void)extractArchivePipingDataToCommand:(NSString *)command
{
	// *** GETS CALLED ON NON-MAIN THREAD!!!
	@autoreleasepool {
		
		
		__block FILE *fp = NULL, *cmdFP = NULL;
		__block char *oldDestinationString = NULL;

		void(^cleanup)(void) = ^{
			if (fp) {
				close(fp);
				fp = NULL;
			}
			
			if (oldDestinationString) {
				setenv("DESTINATION", oldDestinationString, 1);
			} else {
				unsetenv("DESTINATION");
			}
		};
		
		void (^reportError)(void) = ^{
			dispatch_async(dispatch_get_main_queue(), ^{
				[self notifyDelegateOfFailure];
			});
			cleanup();
		};
		
		SULog(@"Extracting %@ using '%@'",archivePath,command);
    
		// Get the file size.
		NSNumber *fs = [[[NSFileManager defaultManager] attributesOfItemAtPath:archivePath error:NULL] objectForKey:NSFileSize];
		if (fs == nil) {
			reportError();
			return;
		}
		
		// Thank you, Allan Odgaard!
		// (who wrote the following extraction alg.)
		fp = fopen([archivePath fileSystemRepresentation], "r");
		if (!fp) {
			
		}
		
		oldDestinationString = getenv("DESTINATION");
		setenv("DESTINATION", [[archivePath stringByDeletingLastPathComponent] fileSystemRepresentation], 1);
		cmdFP = popen([command fileSystemRepresentation], "w");
		size_t written;
		if (!cmdFP) {
			reportError();
			return;
		}
		
		char buf[32*1024];
		size_t len;
		while((len = fread(buf, 1, 32*1024, fp)))
		{				
			written = fwrite(buf, 1, len, cmdFP);
			if( written < len )
			{
				pclose(cmdFP);
				reportError();
				return;
			}
			
			dispatch_async(dispatch_get_main_queue(), ^{
				[self notifyDelegateOfExtractedLength:len];
			});
		}
		pclose(cmdFP);
		
		if( ferror( fp ) ) {
			reportError();
		} else {
			dispatch_async(dispatch_get_main_queue(), ^{
				[self notifyDelegateOfSuccess];
			});
			cleanup();
		}
	}
}

- (void)extractTAR
{
	// *** GETS CALLED ON NON-MAIN THREAD!!!
	
	return [self extractArchivePipingDataToCommand:@"tar -xC \"$DESTINATION\""];
}

- (void)extractTGZ
{
	// *** GETS CALLED ON NON-MAIN THREAD!!!
	
	return [self extractArchivePipingDataToCommand:@"tar -zxC \"$DESTINATION\""];
}

- (void)extractTBZ
{
	// *** GETS CALLED ON NON-MAIN THREAD!!!
	
	return [self extractArchivePipingDataToCommand:@"tar -jxC \"$DESTINATION\""];
}

- (void)extractZIP
{
	// *** GETS CALLED ON NON-MAIN THREAD!!!
	
	return [self extractArchivePipingDataToCommand:@"ditto -x -k - \"$DESTINATION\""];
}

+ (void)load
{
	[self registerImplementation:self];
}

@end
