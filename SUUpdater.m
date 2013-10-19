//
//  SUUpdater.m
//  Sparkle
//
//  Created by Andy Matuschak on 1/4/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#import "SUUpdater_Private.h"
#import <SystemConfiguration/SystemConfiguration.h>

#import "SUHost.h"
#import "SUUpdatePermissionPrompt.h"

#import "SUAutomaticUpdateDriver.h"
#import "SUProbingUpdateDriver.h"
#import "SUUserInitiatedUpdateDriver.h"
#import "SUScheduledUpdateDriver.h"
#import "SULog.h"
#import "SUCodeSigningVerifier.h"

@interface SUUpdater () {
	NSTimer *_checkTimer;
	BOOL _hasObserved;
}

@property (nonatomic, strong) SUUpdateDriver *driver;
@property (nonatomic, strong) SUHost *host;

- (void)startUpdateCycle;
- (void)checkForUpdatesWithDriver:(SUUpdateDriver *)updateDriver;
- (void)scheduleNextUpdateCheck;

- (NSURL *)parameterizedFeedURL;

- (void)registerAsObserver;
- (void)unregisterAsObserver;

- (void)updateDriverDidFinish:(NSNotification *)note;
-(void)	notifyWillShowModalAlert;
-(void)	notifyDidShowModalAlert;

@end

@implementation SUUpdater

#pragma mark Initialization

+ (NSMapTable *)sharedUpdaters
{
	static dispatch_once_t onceToken;
	static NSMapTable *updatersMap = nil;
	dispatch_once(&onceToken, ^{
		updatersMap = [NSMapTable weakToStrongObjectsMapTable];
	});
	return updatersMap;
}

static void *SUUpdaterDefaultsObservationContext = &SUUpdaterDefaultsObservationContext;

+ (SUUpdater *)sharedUpdater
{
	return [self updaterForBundle:[NSBundle mainBundle]];
}

// SUUpdater has a singleton for each bundle. We use the fact that NSBundle instances are also singletons, so we can use them as keys. If you don't trust that you can also use the identifier as key
+ (SUUpdater *)updaterForBundle:(NSBundle *)bundle
{
    if (bundle == nil) bundle = [NSBundle mainBundle];
	
	id updater = [[self sharedUpdaters] objectForKey:bundle];
	if (!updater) {
		updater = [[[self class] alloc] initForBundle:bundle];
	}
	return updater;
}

// This is the designated initializer for SUUpdater, important for subclasses
- (id)initForBundle:(NSBundle *)bundle
{
    if (bundle == nil) bundle = [NSBundle mainBundle];
	
	id updater = [[[self class] sharedUpdaters] objectForKey:bundle];
	if (updater) {
		self = updater;
	} else {
		self = [super init];
		if (self) {
			[[[self class] sharedUpdaters] setObject:self forKey:bundle];
			
			self.host = [[SUHost alloc] initWithBundle:bundle];
			
#if !ENDANGER_USERS_WITH_INSECURE_UPDATES
			// Saving-the-developer-from-a-stupid-mistake-check:
			BOOL hasPublicDSAKey = self.host.publicDSAKey != nil;
			BOOL isMainBundle = [bundle isEqualTo:[NSBundle mainBundle]];
			BOOL hostIsCodeSigned = [SUCodeSigningVerifier hostApplicationIsCodeSigned];
			if (!isMainBundle && !hasPublicDSAKey) {
				[self notifyWillShowModalAlert];
				NSRunAlertPanel(@"Insecure update error!", @"For security reasons, you need to sign your updates with a DSA key. See Sparkle's documentation for more information.", @"OK", nil, nil);
				[self notifyDidShowModalAlert];
			} else if (isMainBundle && !(hasPublicDSAKey || hostIsCodeSigned)) {
				[self notifyWillShowModalAlert];
				NSRunAlertPanel(@"Insecure update error!", @"For security reasons, you need to code sign your application or sign your updates with a DSA key. See Sparkle's documentation for more information.", @"OK", nil, nil);
				[self notifyDidShowModalAlert];
			}
#endif
			// This runs the permission prompt if needed, but never before the app has finished launching because the runloop won't run before that
			[self performSelector:@selector(startUpdateCycle) withObject:nil afterDelay:0];
		}
	}
	return self;
}

// This will be used when the updater is instantiated in a nib such as MainMenu
- (id)init
{
    return [self initForBundle:[NSBundle mainBundle]];
}

- (NSString *)description {
	return [NSString stringWithFormat:@"%@ <%@, %@>", self.className, self.host.bundlePath, self.host.installationPath];
}

-(void)	notifyWillShowModalAlert
{
	id <SUUpdaterDelegate> delegate = self.delegate;
	if( [delegate respondsToSelector: @selector(updaterWillShowModalAlert:)] ) {
		[delegate updaterWillShowModalAlert: self];
	}
}


-(void)	notifyDidShowModalAlert
{
	id <SUUpdaterDelegate> delegate = self.delegate;
	if( [delegate respondsToSelector: @selector(updaterDidShowModalAlert:)] ) {
		[delegate updaterDidShowModalAlert: self];
	}
}


- (void)startUpdateCycle
{
    BOOL shouldPrompt = NO;
	id <SUUpdaterDelegate> delegate = self.delegate;
    
	// If the user has been asked about automatic checks, don't bother prompting
	if ([self.host objectForUserDefaultsKey:SUEnableAutomaticChecksKey]) {
        shouldPrompt = NO;
    }
    // Does the delegate want to take care of the logic for when we should ask permission to update?
    else if ([delegate respondsToSelector:@selector(updaterShouldPromptForPermissionToCheckForUpdates:)])
    {
        shouldPrompt = [delegate updaterShouldPromptForPermissionToCheckForUpdates:self];
    }	
    // Has he been asked already? And don't ask if the host has a default value set in its Info.plist.
    else if ([self.host objectForKey:SUEnableAutomaticChecksKey] == nil)
    {
        if ([self.host objectForUserDefaultsKey:SUEnableAutomaticChecksKeyOld])
            [self setAutomaticallyChecksForUpdates:[self.host boolForUserDefaultsKey:SUEnableAutomaticChecksKeyOld]];
        // Now, we don't want to ask the user for permission to do a weird thing on the first launch.
        // We wait until the second launch, unless explicitly overridden via SUPromptUserOnFirstLaunchKey.
        else if (![self.host objectForKey:SUPromptUserOnFirstLaunchKey])
        {
            if ([self.host boolForUserDefaultsKey:SUHasLaunchedBeforeKey] == NO)
                [self.host setBool:YES forUserDefaultsKey:SUHasLaunchedBeforeKey];
            else
                shouldPrompt = YES;
        }
        else
            shouldPrompt = YES;
    }
    
    if (shouldPrompt)
    {
		NSArray *profileInfo = self.host.systemProfile;
		// Always say we're sending the system profile here so that the delegate displays the parameters it would send.
		if ([delegate respondsToSelector:@selector(feedParametersForUpdater:sendingSystemProfile:)]) 
			profileInfo = [profileInfo arrayByAddingObjectsFromArray:[delegate feedParametersForUpdater:self sendingSystemProfile:YES]];
		
		// We start the update checks and register as observer for changes after the prompt finishes
        [SUUpdatePermissionPrompt promptWithHost:self.host systemProfile:profileInfo completion:^(SUPermissionPromptResult result) {
			[self setAutomaticallyChecksForUpdates:(result == SUAutomaticallyCheck)];
			// Schedule checks, but make sure we ignore the delayed call from KVO
			[self resetUpdateCycle];

		}];
	}
    else 
    {
        // We check if the user's said they want updates, or they haven't said anything, and the default is set to checking.
        [self scheduleNextUpdateCheck];
    }
}

- (void)updatePermissionPromptFinishedWithResult:(SUPermissionPromptResult)result
{
}

- (void)updateDriverDidFinish:(NSNotification *)note
{
	if ([note.object isEqual:self.driver] && self.driver.finished)
	{
		self.driver = nil;
		[self scheduleNextUpdateCheck];
    }
}

- (NSDate *)lastUpdateCheckDate
{
	return [self.host objectForUserDefaultsKey:SULastCheckTimeKey];
}

- (void)scheduleNextUpdateCheck
{	
	if (_checkTimer) {
		[_checkTimer invalidate];
				// UK 2009-03-16 Timer is non-repeating, may have invalidated itself, so we had to retain it.
		_checkTimer = nil;
	}
	if (![self automaticallyChecksForUpdates]) return;
	
	// How long has it been since last we checked for an update?
	NSDate *lastCheckDate = [self lastUpdateCheckDate];
	if (!lastCheckDate) { lastCheckDate = [NSDate distantPast]; }
	NSTimeInterval intervalSinceCheck = [[NSDate date] timeIntervalSinceDate:lastCheckDate];
	
	// Now we want to figure out how long until we check again.
	NSTimeInterval delayUntilCheck, updateCheckInterval = [self updateCheckInterval];
	if (updateCheckInterval < SU_MIN_CHECK_INTERVAL)
		updateCheckInterval = SU_MIN_CHECK_INTERVAL;
	if (intervalSinceCheck < updateCheckInterval)
		delayUntilCheck = (updateCheckInterval - intervalSinceCheck); // It hasn't been long enough.
	else
		delayUntilCheck = 0; // We're overdue! Run one now.
	
	_checkTimer = [NSTimer scheduledTimerWithTimeInterval:delayUntilCheck target:self selector:@selector(checkForUpdatesInBackground) userInfo:nil repeats:NO];		// UK 2009-03-16 Timer is non-repeating, may have invalidated itself, so we had to retain it.
}


-(void)	putFeedURLIntoDictionary: (NSMutableDictionary*)theDict	// You release this.
{
	NSURL *URL = self.feedURL;
	if (URL) {
		theDict[@"feedURL"] = URL;
	}
}

-(void)	checkForUpdatesInBgReachabilityCheckWithDriver: (SUUpdateDriver*)inDriver /* RUNS ON ITS OWN THREAD */
{
	@autoreleasepool {
		@try {
			// This method *must* be called on its own thread. SCNetworkReachabilityCheckByName
			//	can block, and it can be waiting a long time on slow networks, and we
			//	wouldn't want to beachball the main thread for a background operation.
			// We could use asynchronous reachability callbacks, but those aren't
			//	reliable enough and can 'get lost' sometimes, which we don't want.

			SCNetworkConnectionFlags flags = 0;
			BOOL isNetworkReachable = YES;
			
			// Don't perform automatic checks on unconnected laptops or dial-up connections that aren't online:
			NSMutableDictionary*		theDict = [NSMutableDictionary dictionary];
			dispatch_sync(dispatch_get_main_queue(), ^{
				[self putFeedURLIntoDictionary:theDict];
			});
			
			const char *hostname = [[[theDict objectForKey: @"feedURL"] host] cStringUsingEncoding: NSUTF8StringEncoding];
			SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(NULL, hostname);
			Boolean reachabilityResult = NO;
			// If the feed's using a file:// URL, we won't be able to use reachability.
			if (reachability != NULL) {
				SCNetworkReachabilityGetFlags(reachability, &flags);
				CFRelease(reachability);
			}
			
			if( reachabilityResult )
			{
				BOOL reachable =	(flags & kSCNetworkFlagsReachable)				== kSCNetworkFlagsReachable;
				BOOL automatic =	(flags & kSCNetworkFlagsConnectionAutomatic)	== kSCNetworkFlagsConnectionAutomatic;
				BOOL local =		(flags & kSCNetworkFlagsIsLocalAddress)			== kSCNetworkFlagsIsLocalAddress;
				
				//NSLog(@"reachable = %s, automatic = %s, local = %s", (reachable?"YES":"NO"), (automatic?"YES":"NO"), (local?"YES":"NO"));
				
				if( !(reachable || automatic || local) )
					isNetworkReachable = NO;
			}
			
			// If the network's not reachable, we pass a nil driver into checkForUpdatesWithDriver, which will then reschedule the next update so we try again later.
			dispatch_async(dispatch_get_main_queue(), ^{
				[self checkForUpdatesWithDriver:(isNetworkReachable ? inDriver : nil)];
			});
		}
		@catch (NSException *exception) {
			SULog(@"UNCAUGHT EXCEPTION IN UPDATE CHECK TIMER: %@",[exception reason]);
			// Don't propagate the exception beyond here. In Carbon apps that would trash the stack.
		}
	}
}


- (void)checkForUpdatesInBackground
{
	// Background update checks should only happen if we have a network connection.
	//	Wouldn't want to annoy users on dial-up by establishing a connection every
	//	hour or so:
	BOOL automaticallyDownloads = self.automaticallyDownloadsUpdates;
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		Class updateDriver = (automaticallyDownloads ? [SUAutomaticUpdateDriver class] : [SUScheduledUpdateDriver class]);
		SUUpdateDriver *theUpdateDriver = [[updateDriver alloc] initWithUpdater:self];
		[self checkForUpdatesInBgReachabilityCheckWithDriver:theUpdateDriver];
	});
}


- (BOOL)mayUpdateAndRestart
{
	id <SUUpdaterDelegate> delegate = self.delegate;
	return (delegate && [delegate respondsToSelector: @selector(updaterShouldRelaunchApplication:)]  && [delegate updaterShouldRelaunchApplication: self]);
}

- (IBAction)checkForUpdates: (id)sender
{
	[self checkForUpdatesWithDriver:[[SUUserInitiatedUpdateDriver alloc] initWithUpdater:self]];
}

- (void)checkForUpdateInformation
{
	[self checkForUpdatesWithDriver:[[SUProbingUpdateDriver alloc] initWithUpdater:self]];
}

- (void)checkForUpdatesWithDriver:(SUUpdateDriver *)driver
{
	if ([self updateInProgress]) { return; }
	if (_checkTimer) {
		[_checkTimer invalidate];
		_checkTimer = nil;
	}
	
	id <SUUpdaterDelegate> delegate = self.delegate;
	
	SUClearLog();
	SULog( @"===== %@ =====", [[NSFileManager defaultManager] displayNameAtPath: [[NSBundle mainBundle] bundlePath]] );
		
	[self willChangeValueForKey:@"lastUpdateCheckDate"];
	[self.host setObject:[NSDate date] forUserDefaultsKey:SULastCheckTimeKey];
	[self didChangeValueForKey:@"lastUpdateCheckDate"];
	
    if( [delegate respondsToSelector: @selector(updaterMayCheckForUpdates:)] && ![delegate updaterMayCheckForUpdates: self] )
	{
		[self scheduleNextUpdateCheck];
		return;
	}
    	
    self.driver = driver;
    
    // If we're not given a driver at all, just schedule the next update check and bail.
    if (!driver)
    {
        [self scheduleNextUpdateCheck];
        return;
    }
    
	NSURL*	theFeedURL = [self parameterizedFeedURL];
	if( theFeedURL )	// Use a NIL URL to cancel quietly.
		[driver checkForUpdatesAtURL: theFeedURL host:self.host];
	else
		[driver abortUpdate];
}

- (void)registerAsObserver
{
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateDriverDidFinish:) name:SUUpdateDriverFinishedNotification object:nil];
    [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:[@"values." stringByAppendingString:SUScheduledCheckIntervalKey] options:0 context:SUUpdaterDefaultsObservationContext];
    [[NSUserDefaultsController sharedUserDefaultsController] addObserver:self forKeyPath:[@"values." stringByAppendingString:SUEnableAutomaticChecksKey] options:0 context:SUUpdaterDefaultsObservationContext];
	_hasObserved = YES;
}

- (void)unregisterAsObserver
{
	if (!_hasObserved) return;
	@try
	{
		[[NSNotificationCenter defaultCenter] removeObserver:self];
		[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:[@"values." stringByAppendingString:SUScheduledCheckIntervalKey]];
		[[NSUserDefaultsController sharedUserDefaultsController] removeObserver:self forKeyPath:[@"values." stringByAppendingString:SUEnableAutomaticChecksKey]];
		_hasObserved = NO;
	}
	@catch (NSException *e)
	{
		NSLog(@"Sparkle Error: [SUUpdater unregisterAsObserver] called, but the updater wasn't registered as an observer.");
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context == SUUpdaterDefaultsObservationContext)
    {
        // Allow a small delay, because perhaps the user or developer wants to change both preferences. This allows the developer to interpret a zero check interval as a sign to disable automatic checking.
        // Or we may get this from the developer and from our own KVO observation, this will effectively coalesce them.
        [[self class] cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetUpdateCycle) object:nil];
        [self performSelector:@selector(resetUpdateCycle) withObject:nil afterDelay:1];
    }
    else
    {
    	[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)resetUpdateCycle
{
    [[self class] cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetUpdateCycle) object:nil];
    [self scheduleNextUpdateCheck];
}

- (void)setAutomaticallyChecksForUpdates:(BOOL)automaticallyCheckForUpdates
{
	[self.host setBool:automaticallyCheckForUpdates forUserDefaultsKey:SUEnableAutomaticChecksKey];
	// Hack to support backwards compatibility with older Sparkle versions, which supported
	// disabling updates by setting the check interval to 0.
    if (automaticallyCheckForUpdates && self.updateCheckInterval == 0) {
		self.updateCheckInterval = SU_DEFAULT_CHECK_INTERVAL;
	}
	
    [[self class] cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetUpdateCycle) object:nil];
	// Provide a small delay in case multiple preferences are being updated simultaneously.
    [self performSelector:@selector(resetUpdateCycle) withObject:nil afterDelay:1];
}

- (BOOL)automaticallyChecksForUpdates
{
	// Don't automatically update when the check interval is 0, to be compatible with 1.1 settings.
    if (self.updateCheckInterval == 0) {
        return NO;
	}
	
	return [self.host boolForKey:SUEnableAutomaticChecksKey];
}

- (void)setAutomaticallyDownloadsUpdates:(BOOL)automaticallyUpdates
{
	[self.host setBool:automaticallyUpdates forUserDefaultsKey:SUAutomaticallyUpdateKey];
}

- (BOOL)automaticallyDownloadsUpdates
{
	// If the SUAllowsAutomaticUpdatesKey exists and is set to NO, return NO.
	if ([self.host objectForInfoDictionaryKey:SUAllowsAutomaticUpdatesKey] && [self.host boolForInfoDictionaryKey:SUAllowsAutomaticUpdatesKey] == NO)
		return NO;
	
	// Otherwise, automatically downloading updates is allowed. Does the user want it?
	return [self.host boolForUserDefaultsKey:SUAutomaticallyUpdateKey];
}

- (void)setFeedURL:(NSURL *)feedURL
{
	[self.host setObject:[feedURL absoluteString] forUserDefaultsKey:SUFeedURLKey];
}

- (NSURL *)feedURL // *** MUST BE CALLED ON MAIN THREAD ***
{
	// A value in the user defaults overrides one in the Info.plist (so preferences panels can be created wherein users choose between beta / release feeds).
	NSString *appcastString = [self.host objectForKey:SUFeedURLKey];
	id <SUUpdaterDelegate> delegate = self.delegate;
	if( [delegate respondsToSelector: @selector(feedURLStringForUpdater:)] )
		appcastString = [delegate feedURLStringForUpdater: self];
	if (!appcastString) // Can't find an appcast string!
		[NSException raise:@"SUNoFeedURL" format:@"You must specify the URL of the appcast as the SUFeedURL key in either the Info.plist or the user defaults!"];
	NSCharacterSet* quoteSet = [NSCharacterSet characterSetWithCharactersInString: @"\"\'"]; // Some feed publishers add quotes; strip 'em.
	NSString*	castUrlStr = [appcastString stringByTrimmingCharactersInSet:quoteSet];
	if( !castUrlStr || [castUrlStr length] == 0 )
		return nil;
	else
		return [NSURL URLWithString: castUrlStr];
}

- (NSString *)userAgentString
{
	if (_userAgentString.length)
		return _userAgentString;

	NSString *version = [SUBundle() objectForInfoDictionaryKey:(__bridge id)kCFBundleVersionKey];
	NSString *userAgent = [NSString stringWithFormat:@"%@/%@ Sparkle/%@", self.host.name, self.host.displayVersion, version ? version : @"?"];
	NSData *cleanedAgent = [userAgent dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
	return [[NSString alloc] initWithData:cleanedAgent encoding:NSASCIIStringEncoding];
}

- (void)setSendsSystemProfile:(BOOL)sendsSystemProfile
{
	[self.host setBool:sendsSystemProfile forUserDefaultsKey:SUSendProfileInfoKey];
}

- (BOOL)sendsSystemProfile
{
	return [self.host boolForUserDefaultsKey:SUSendProfileInfoKey];
}

- (NSURL *)parameterizedFeedURL
{
	NSURL *baseFeedURL = self.feedURL;
	id <SUUpdaterDelegate> delegate = self.delegate;
	
	// Determine all the parameters we're attaching to the base feed URL.
	BOOL sendingSystemProfile = self.sendsSystemProfile;

	// Let's only send the system profiling information once per week at most, so we normalize daily-checkers vs. biweekly-checkers and the such.
	NSDate *lastSubmitDate = [self.host objectForUserDefaultsKey:SULastProfileSubmitDateKey];
	if(!lastSubmitDate)
	    lastSubmitDate = [NSDate distantPast];
	const NSTimeInterval oneWeek = 60 * 60 * 24 * 7;
	sendingSystemProfile &= (-[lastSubmitDate timeIntervalSinceNow] >= oneWeek);

	NSArray *parameters = [NSArray array];
	if ([delegate respondsToSelector:@selector(feedParametersForUpdater:sendingSystemProfile:)])
		parameters = [parameters arrayByAddingObjectsFromArray:[delegate feedParametersForUpdater:self sendingSystemProfile:sendingSystemProfile]];
	if (sendingSystemProfile)
	{
		parameters = [parameters arrayByAddingObjectsFromArray:self.host.systemProfile];
		[self.host setObject:[NSDate date] forUserDefaultsKey:SULastProfileSubmitDateKey];
	}
	if ([parameters count] == 0) { return baseFeedURL; }
	
	// Build up the parameterized URL.
	NSMutableArray *parameterStrings = [NSMutableArray array];
	NSEnumerator *profileInfoEnumerator = [parameters objectEnumerator];
	NSDictionary *currentProfileInfo;
	while ((currentProfileInfo = [profileInfoEnumerator nextObject]))
		[parameterStrings addObject:[NSString stringWithFormat:@"%@=%@", [[[currentProfileInfo objectForKey:@"key"] description] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding], [[[currentProfileInfo objectForKey:@"value"] description] stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
	
	NSString *separatorCharacter = @"?";
	if ([baseFeedURL query])
		separatorCharacter = @"&"; // In case the URL is already http://foo.org/baz.xml?bat=4
	NSString *appcastStringWithProfile = [NSString stringWithFormat:@"%@%@%@", [baseFeedURL absoluteString], separatorCharacter, [parameterStrings componentsJoinedByString:@"&"]];
	
	// Clean it up so it's a valid URL
	return [NSURL URLWithString:appcastStringWithProfile];
}

- (void)setUpdateCheckInterval:(NSTimeInterval)updateCheckInterval
{
	[self.host setObject:@(updateCheckInterval) forUserDefaultsKey:SUScheduledCheckIntervalKey];
	
	if (updateCheckInterval == 0) // For compatibility with 1.1's settings.
		[self setAutomaticallyChecksForUpdates:NO];
	
	[[self class] cancelPreviousPerformRequestsWithTarget:self selector:@selector(resetUpdateCycle) object:nil];
	
	// Provide a small delay in case multiple preferences are being updated simultaneously.
	[self performSelector:@selector(resetUpdateCycle) withObject:nil afterDelay:1];
}

- (NSTimeInterval)updateCheckInterval
{
	// Find the stored check interval. User defaults override Info.plist.
	NSNumber *intervalValue = [self.host objectForKey:SUScheduledCheckIntervalKey];
	if (intervalValue)
		return [intervalValue doubleValue];
	else
		return SU_DEFAULT_CHECK_INTERVAL;
}

- (void)dealloc
{
	[self unregisterAsObserver];
	[_checkTimer invalidate];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
	if ([item action] == @selector(checkForUpdates:))
		return ![self updateInProgress];
	return YES;
}

- (BOOL)updateInProgress
{
	return self.driver && !self.driver.finished;
}

@end
