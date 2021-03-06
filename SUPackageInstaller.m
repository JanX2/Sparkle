//
//  SUPackageInstaller.m
//  Sparkle
//
//  Created by Andy Matuschak on 4/10/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUPackageInstaller.h"
#import <Cocoa/Cocoa.h>
#import "SUConstants.h"

NSString *SUPackageInstallerCommandKey = @"SUPackageInstallerCommand";
NSString *SUPackageInstallerArgumentsKey = @"SUPackageInstallerArguments";
NSString *SUPackageInstallerHostKey = @"SUPackageInstallerHost";
NSString *SUPackageInstallerDelegateKey = @"SUPackageInstallerDelegate";
NSString *SUPackageInstallerInstallationPathKey = @"SUPackageInstallerInstallationPathKey";

@implementation SUPackageInstaller

+ (void)finishInstallationWithInfo:(NSDictionary *)info
{
	[self finishInstallationToPath:[info objectForKey:SUPackageInstallerInstallationPathKey] withResult:YES host:[info objectForKey:SUPackageInstallerHostKey] error:nil delegate:[info objectForKey:SUPackageInstallerDelegateKey]];
}

+ (void)performInstallationWithInfo:(NSDictionary *)info
{
	@autoreleasepool {
		NSTask *installer = [NSTask launchedTaskWithLaunchPath:[info objectForKey:SUPackageInstallerCommandKey] arguments:[info objectForKey:SUPackageInstallerArgumentsKey]];
		[installer waitUntilExit];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			[self finishInstallationWithInfo:info];
		});
	}
}

+ (void)performInstallationToPath:(NSString *)installationPath fromPath:(NSString *)path host:(SUHost *)host delegate:(id <SUInstallerDelegate>)delegate synchronously:(BOOL)synchronously versionComparator:(id <SUVersionComparison>)comparator
{
	NSString *command = @"/usr/bin/open";
	NSArray *args = [NSArray arrayWithObjects:@"-W", @"-n", @"-b", @"com.apple.installer", path, nil];

	if (![[NSFileManager defaultManager] fileExistsAtPath:command])
	{
		NSError *error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUMissingInstallerToolError userInfo:[NSDictionary dictionaryWithObject:@"Couldn't find Apple's installer tool!" forKey:NSLocalizedDescriptionKey]];
		[self finishInstallationToPath:installationPath withResult:NO host:host error:error delegate:delegate];
	}
	else 
	{
		NSDictionary *info = [NSDictionary dictionaryWithObjectsAndKeys:command, SUPackageInstallerCommandKey, args, SUPackageInstallerArgumentsKey, host, SUPackageInstallerHostKey, delegate, SUPackageInstallerDelegateKey, installationPath, SUPackageInstallerInstallationPathKey, nil];
		if (synchronously) {
			[self performInstallationWithInfo:info];
		} else {
			dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
				[self performInstallationWithInfo:info];
			});
		}
	}
}

@end
