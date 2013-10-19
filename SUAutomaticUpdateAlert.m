//
//  SUAutomaticUpdateAlert.m
//  Sparkle
//
//  Created by Andy Matuschak on 3/18/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#import "SUAutomaticUpdateAlert.h"
#import "SUHost.h"

@interface SUAutomaticUpdateAlert () {
	SUAppcastItem *updateItem;
	SUHost *host;
}

@property (nonatomic, copy) void(^completionBlock)(SUAutomaticInstallationChoice);

@end

@implementation SUAutomaticUpdateAlert

- (id)initWithAppcastItem:(SUAppcastItem *)item host:(SUHost *)aHost completion:(void (^)(SUAutomaticInstallationChoice))block
{
	self = [super initWithHost:aHost windowNibName:@"SUAutomaticUpdateAlert"];
	if (self)
	{
		updateItem = item;
		self.completionBlock = block;
		host = aHost;
		[self setShouldCascadeWindows:NO];	
		[[self window] center];
	}
	return self;
}


- (NSString *)description { return [NSString stringWithFormat:@"%@ <%@, %@>", [self class], [host bundlePath], [host installationPath]]; }

- (IBAction)installNow:sender
{
	[self close];
	if (self.completionBlock) {
		self.completionBlock(SUInstallNowChoice);
	}
}

- (IBAction)installLater:sender
{
	[self close];
	if (self.completionBlock) {
		self.completionBlock(SUInstallLaterChoice);
	}
}

- (IBAction)doNotInstall:sender
{
	[self close];
	if (self.completionBlock) {
		self.completionBlock(SUDoNotInstallChoice);
	}
}

- (NSImage *)applicationIcon
{
	return [host icon];
}

- (NSString *)titleText
{
	return [NSString stringWithFormat:SULocalizedString(@"A new version of %@ is ready to install!", nil), [host name]];
}

- (NSString *)descriptionText
{
	return [NSString stringWithFormat:SULocalizedString(@"%1$@ %2$@ has been downloaded and is ready to use! Would you like to install it and relaunch %1$@ now?", nil), [host name], [updateItem displayVersionString]];
}

@end
