//
//  SUUpdatePermissionPrompt.m
//  Sparkle
//
//  Created by Andy Matuschak on 1/24/08.
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUUpdatePermissionPrompt.h"

#import "SUHost.h"
#import "SUConstants.h"

@interface SUUpdatePermissionPrompt () {
	SUHost *host;
	NSArray *systemProfileInformationArray;
	IBOutlet NSTextField *descriptionTextField;
	IBOutlet NSView *moreInfoView;
	IBOutlet NSButton *moreInfoButton;
    IBOutlet NSTableView *profileTableView;
	BOOL isShowingMoreInfo, shouldSendProfile;
}

@property (nonatomic, copy) void(^completionBlock)(SUPermissionPromptResult);

@end

@implementation SUUpdatePermissionPrompt

- (BOOL)shouldAskAboutProfile
{
	return [[host objectForInfoDictionaryKey:SUEnableSystemProfilingKey] boolValue];
}

- (id)initWithHost:(SUHost *)aHost systemProfile:(NSArray *)profile
{
	self = [super initWithHost:aHost windowNibName:@"SUUpdatePermissionPrompt"];
	if (self)
	{
		host = aHost;
		isShowingMoreInfo = NO;
		shouldSendProfile = [self shouldAskAboutProfile];
		systemProfileInformationArray = profile;
		[self setShouldCascadeWindows:NO];
	}
	return self;
}

+ (void)promptWithHost:(SUHost *)aHost systemProfile:(NSArray *)profile completion:(void (^)(SUPermissionPromptResult))block
{
	// If this is a background application we need to focus it in order to bring the prompt
	// to the user's attention. Otherwise the prompt would be hidden behind other applications and
	// the user would not know why the application was paused.
	if ([aHost isBackgroundApplication]) { [NSApp activateIgnoringOtherApps:YES]; }
	
	SUUpdatePermissionPrompt *prompt = [[[self class] alloc] initWithHost:aHost systemProfile:profile];
	prompt.completionBlock = block;
		
	[NSApp runModalForWindow:[prompt window]];
}

- (NSString *)description { return [NSString stringWithFormat:@"%@ <%@>", [self class], [host bundlePath]]; }

- (void)awakeFromNib
{
	if (![self shouldAskAboutProfile])
	{
		NSRect frame = [[self window] frame];
		frame.size.height -= [moreInfoButton frame].size.height;
		[[self window] setFrame:frame display:YES];
	} else {
        // Set the table view's delegate so we can disable row selection.
        [profileTableView setDelegate:(id)self];
    }
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row { return NO; }


- (NSImage *)icon
{
	return [host icon];
}

- (NSString *)promptDescription
{
	return [NSString stringWithFormat:SULocalizedString(@"Should %1$@ automatically check for updates? You can always check for updates manually from the %1$@ menu.", nil), [host name]];
}

- (IBAction)toggleMoreInfo:(id)sender
{
	[self willChangeValueForKey:@"isShowingMoreInfo"];
	isShowingMoreInfo = !isShowingMoreInfo;
	[self didChangeValueForKey:@"isShowingMoreInfo"];
	
	NSView *contentView = [[self window] contentView];
	NSRect contentViewFrame = [contentView frame];
	NSRect windowFrame = [[self window] frame];
	
	NSRect profileMoreInfoViewFrame = [moreInfoView frame];
	NSRect profileMoreInfoButtonFrame = [moreInfoButton frame];
	NSRect descriptionFrame = [descriptionTextField frame];
	
	if (isShowingMoreInfo)
	{
		// Add the subview
		contentViewFrame.size.height += profileMoreInfoViewFrame.size.height;
		profileMoreInfoViewFrame.origin.y = profileMoreInfoButtonFrame.origin.y - profileMoreInfoViewFrame.size.height;
		profileMoreInfoViewFrame.origin.x = descriptionFrame.origin.x;
		profileMoreInfoViewFrame.size.width = descriptionFrame.size.width;
		
		windowFrame.size.height += profileMoreInfoViewFrame.size.height;
		windowFrame.origin.y -= profileMoreInfoViewFrame.size.height;
		
		[moreInfoView setFrame:profileMoreInfoViewFrame];
		[moreInfoView setHidden:YES];
		[contentView addSubview:moreInfoView
					 positioned:NSWindowBelow
					 relativeTo:moreInfoButton];
	} else {
		// Remove the subview
		[moreInfoView setHidden:NO];
		[moreInfoView removeFromSuperview];
		contentViewFrame.size.height -= profileMoreInfoViewFrame.size.height;
		
		windowFrame.size.height -= profileMoreInfoViewFrame.size.height;
		windowFrame.origin.y += profileMoreInfoViewFrame.size.height;
	}
	[[self window] setFrame:windowFrame display:YES animate:YES];
	[contentView setFrame:contentViewFrame];
	[contentView setNeedsDisplay:YES];
	[moreInfoView setHidden:(!isShowingMoreInfo)];
}

- (IBAction)finishPrompt:(id)sender
{
	if (!self.completionBlock)
		[NSException raise:@"SUInvalidDelegate" format:@"SUUpdatePermissionPrompt wasn't provided a completion block!"];
	[host setBool:shouldSendProfile forUserDefaultsKey:SUSendProfileInfoKey];
	self.completionBlock(([sender tag] == 1 ? SUAutomaticallyCheck : SUDoNotAutomaticallyCheck));
	[[self window] close];
	[NSApp stopModal];
}

@end
