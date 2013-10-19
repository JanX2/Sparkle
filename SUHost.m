//
//  SUHost.m
//  Sparkle
//
//  Copyright 2008 Andy Matuschak. All rights reserved.
//

#import "SUHost.h"

#import "SUConstants.h"
#import "SUSystemProfiler.h"
#import <sys/mount.h> // For statfs for isRunningOnReadOnlyVolume
#import "SULog.h"

@interface SUHost ()

@property (nonatomic, strong) NSBundle *bundle;
@property (nonatomic, copy) NSString *defaultsDomain;
@property (nonatomic, readonly) NSString *bundlePath;
@property (nonatomic) BOOL usesStandardUserDefaults;

@end

@implementation SUHost

- (id)initWithBundle:(NSBundle *)bundle
{
	if ((self = [super init]))
	{
		if (!bundle) bundle = [NSBundle mainBundle];
		
		self.bundle = bundle;
		if (!bundle.bundleIdentifier)
			SULog(@"Sparkle Error: the bundle being updated at %@ has no CFBundleIdentifier! This will cause preference read/write to not work properly.", bundle);

		self.defaultsDomain = [bundle objectForInfoDictionaryKey:SUDefaultsDomainKey] ?: bundle.bundleIdentifier;

		// If we're using the main bundle's defaults we'll use the standard user defaults mechanism, otherwise we have to get CF-y.
		self.usesStandardUserDefaults = [self.defaultsDomain isEqualToString:[[NSBundle mainBundle] bundleIdentifier]];
    }
    return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"%@ <%@, %@>", [self class], [self bundlePath], [self installationPath]];
}

- (NSString *)bundlePath
{
    return [self.bundle bundlePath];
}

- (NSString *)appSupportPath
{
    NSArray *appSupportPaths = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString *appSupportPath = nil;
    if (!appSupportPaths || [appSupportPaths count] == 0)
    {
        SULog(@"Failed to find app support directory! Using ~/Library/Application Support...");
        appSupportPath = [@"~/Library/Application Support" stringByExpandingTildeInPath];
    }
    else
        appSupportPath = [appSupportPaths objectAtIndex:0];
    appSupportPath = [appSupportPath stringByAppendingPathComponent:[self name]];
    return appSupportPath;
}

- (NSString *)installationPath
{
#if NORMALIZE_INSTALLED_APP_NAME
    // We'll install to "#{CFBundleName}.app", but only if that path doesn't already exist. If we're "Foo 4.2.app," and there's a "Foo.app" in this directory, we don't want to overwrite it! But if there's no "Foo.app," we'll take that name.
    NSString *normalizedAppPath = [[self.bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent: [NSString stringWithFormat: @"%@.%@", [self.bundle objectForInfoDictionaryKey:@"CFBundleName"], [self.bundlePath pathExtension]]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[[self.bundlePath stringByDeletingLastPathComponent] stringByAppendingPathComponent: [NSString stringWithFormat: @"%@.%@", [self.bundle objectForInfoDictionaryKey:@"CFBundleName"], [self.bundlePath pathExtension]]]])
        return normalizedAppPath;
#endif
	return self.bundlePath;
}

- (NSString *)name
{
	NSString *name = [self.bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
	if (name) return name;
	
	name = [self objectForInfoDictionaryKey:@"CFBundleName"];
	if (name) return name;
	
	return [[[NSFileManager defaultManager] displayNameAtPath:self.bundlePath] stringByDeletingPathExtension];
}

- (NSString *)version
{
	NSString *version = [self.bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
	if (!version || [version isEqualToString:@""])
		[NSException raise:@"SUNoVersionException" format:@"This host (%@) has no CFBundleVersion! This attribute is required.", [self bundlePath]];
	return version;
}

- (NSString *)displayVersion
{
	NSString *shortVersionString = [self.bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
	if (shortVersionString)
		return shortVersionString;
	else
		return [self version]; // Fall back on the normal version string.
}

- (NSImage *)icon
{
	// Cache the application icon.
	NSBundle *bundle = self.bundle;
	NSString *iconPath = [bundle pathForResource:[bundle objectForInfoDictionaryKey:@"CFBundleIconFile"] ofType:@"icns"];
	// According to the OS X docs, "CFBundleIconFile - This key identifies the file containing
	// the icon for the bundle. The filename you specify does not need to include the .icns
	// extension, although it may."
	//
	// However, if it *does* include the '.icns' the above method fails (tested on OS X 10.3.9) so we'll also try:
	if (!iconPath)
		iconPath = [bundle pathForResource:[bundle objectForInfoDictionaryKey:@"CFBundleIconFile"] ofType: nil];
	NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
	// Use a default icon if none is defined.
	if (!icon) {
		BOOL isMainBundle = (bundle == [NSBundle mainBundle]);
		
		// Starting with 10.6, iconForFileType: accepts a UTI.
		NSString *fileType = isMainBundle ? (NSString*)kUTTypeApplication : (NSString*)kUTTypeBundle;
		icon = [[NSWorkspace sharedWorkspace] iconForFileType:fileType];
	}
	return icon;
}

- (BOOL)isRunningOnReadOnlyVolume
{	
	struct statfs statfs_info;
	statfs([self.bundlePath fileSystemRepresentation], &statfs_info);
	return (statfs_info.f_flags & MNT_RDONLY);
}

- (BOOL)isBackgroundApplication
{
	return ([[NSApplication sharedApplication] activationPolicy] == NSApplicationActivationPolicyAccessory);
}

- (NSString *)publicDSAKey
{
	// Maybe the key is just a string in the Info.plist.
	NSString *key = [self.bundle objectForInfoDictionaryKey:SUPublicDSAKeyKey];
	if (key) { return key; }
	
	// More likely, we've got a reference to a Resources file by filename:
	NSString *keyFilename = [self objectForInfoDictionaryKey:SUPublicDSAKeyFileKey];
	if (!keyFilename) { return nil; }
	
	return [NSString stringWithContentsOfFile:[self.bundle pathForResource:keyFilename ofType:nil] encoding:NSASCIIStringEncoding error:NULL];
}

- (NSArray *)systemProfile
{
	return [[SUSystemProfiler sharedSystemProfiler] systemProfileArrayForHost:self];
}

- (id)objectForInfoDictionaryKey:(NSString *)key
{
    return [self.bundle objectForInfoDictionaryKey:key];
}

- (BOOL)boolForInfoDictionaryKey:(NSString *)key
{
	return [[self objectForInfoDictionaryKey:key] boolValue];
}

- (id)objectForUserDefaultsKey:(NSString *)defaultName
{
	// Under Tiger, CFPreferencesCopyAppValue doesn't get values from NSRegistrationDomain, so anything
	// passed into -[NSUserDefaults registerDefaults:] is ignored.  The following line falls
	// back to using NSUserDefaults, but only if the host bundle is the main bundle.
	if (self.usesStandardUserDefaults)
		return [[NSUserDefaults standardUserDefaults] objectForKey:defaultName];
	
	CFPropertyListRef obj = CFPreferencesCopyAppValue((__bridge CFStringRef)defaultName, (__bridge CFStringRef)self.defaultsDomain);
	return (__bridge_transfer id)obj;
}

- (void)setObject:(id)value forUserDefaultsKey:(NSString *)defaultName;
{
	if (self.usesStandardUserDefaults)
	{
		[[NSUserDefaults standardUserDefaults] setObject:value forKey:defaultName];
	}
	else
	{
		CFPreferencesSetValue((__bridge CFStringRef)defaultName, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)self.defaultsDomain,  kCFPreferencesCurrentUser,  kCFPreferencesAnyHost);
		CFPreferencesSynchronize((__bridge CFStringRef)self.defaultsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	}
}

- (BOOL)boolForUserDefaultsKey:(NSString *)defaultName
{
	if (self.usesStandardUserDefaults) {
		return [[NSUserDefaults standardUserDefaults] boolForKey:defaultName];
	}
	
	CFPropertyListRef plr = CFPreferencesCopyAppValue((__bridge CFStringRef)defaultName, (__bridge CFStringRef)self.defaultsDomain);
	if (plr) {
		return [(__bridge_transfer NSNumber *)plr boolValue];
	}
	return NO;
	
}

- (void)setBool:(BOOL)value forUserDefaultsKey:(NSString *)defaultName
{
	if (self.usesStandardUserDefaults)
	{
		[[NSUserDefaults standardUserDefaults] setBool:value forKey:defaultName];
	}
	else
	{
		CFPreferencesSetValue((__bridge CFStringRef)defaultName, value ? kCFBooleanTrue : kCFBooleanFalse, (__bridge CFStringRef)self.defaultsDomain,  kCFPreferencesCurrentUser,  kCFPreferencesAnyHost);
		CFPreferencesSynchronize((__bridge CFStringRef)self.defaultsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	}
}

- (id)objectForKey:(NSString *)key {
    return [self objectForUserDefaultsKey:key] ? [self objectForUserDefaultsKey:key] : [self objectForInfoDictionaryKey:key];
}

- (BOOL)boolForKey:(NSString *)key {
    return [self objectForUserDefaultsKey:key] ? [self boolForUserDefaultsKey:key] : [self boolForInfoDictionaryKey:key];
}

+ (NSString *)systemVersionString
{
	NSString *versionPlistPath = @"/System/Library/CoreServices/SystemVersion.plist";
	return [[NSDictionary dictionaryWithContentsOfFile:versionPlistPath] objectForKey:@"ProductVersion"];
}

@end
