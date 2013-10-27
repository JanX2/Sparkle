//
//  SUPlainInstallerInternals.m
//  Sparkle
//
//  Created by Andy Matuschak on 3/9/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#import "SUUpdater.h"

#import "SUAppcast.h"
#import "SUAppcastItem.h"
#import "SUVersionComparisonProtocol.h"
#import "SUPlainInstallerInternals.h"
#import "SUConstants.h"
#import "SULog.h"

#import <CoreServices/CoreServices.h>
#import <Security/Security.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <dirent.h>
#import <unistd.h>
#import <sys/param.h>
#import <ServiceManagement/ServiceManagement.h>

@interface SUPlainInstaller (MMExtendedAttributes)
+ (void)releaseURLFromQuarantine:(NSURL*)URL;
@end

static OSStatus su_AuthorizationExecuteWithPrivileges(AuthorizationRef authorization, const char *pathToTool, AuthorizationFlags flags, char *const *arguments)
{
	// flags are currently reserved
	if (flags != 0)
		return errAuthorizationInvalidFlags;
	
	char **(^argVector)(const char *, const char *, const char *, char *const *) = ^char **(const char *bTrampoline, const char *bPath,
																				  const char *bMboxFdText, char *const *bArguments){
		int length = 0;
		if (bArguments) {
			for (char *const *p = bArguments; *p; p++)
				length++;
		}
		
		const char **args = (const char **)malloc(sizeof(const char *) * (length + 4));
		if (args) {
			args[0] = bTrampoline;
			args[1] = bPath;
			args[2] = bMboxFdText;
			if (bArguments)
				for (int n = 0; bArguments[n]; n++)
					args[n + 3] = bArguments[n];
			args[length + 3] = NULL;
			return (char **)args;
		}
		return NULL;
	};
	
	// externalize the authorization
	AuthorizationExternalForm extForm;
	OSStatus err;
	if ((err = AuthorizationMakeExternalForm(authorization, &extForm)))
		return err;
	
    // create the mailbox file
    FILE *mbox = tmpfile();
    if (!mbox)
        return errAuthorizationInternal;
    if (fwrite(&extForm, sizeof(extForm), 1, mbox) != 1) {
        fclose(mbox);
        return errAuthorizationInternal;
    }
    fflush(mbox);
    
    // make text representation of the temp-file descriptor
    char mboxFdText[20];
    snprintf(mboxFdText, sizeof(mboxFdText), "auth %d", fileno(mbox));
    
	// make a notifier pipe
	int notify[2];
	if (pipe(notify)) {
        fclose(mbox);
		return errAuthorizationToolExecuteFailure;
    }
	
	// do the standard forking tango...
	int delay = 1;
	for (int n = 5;; n--, delay *= 2) {
		switch (fork()) {
			case -1: { // error
				if (errno == EAGAIN) {
					// potentially recoverable resource shortage
					if (n > 0) {
						sleep(delay);
						continue;
					}
				}
				close(notify[0]); close(notify[1]);
				return errAuthorizationToolExecuteFailure;
			}
				
			default: {	// parent
				// close foreign side of pipes
				close(notify[1]);
                
				// close mailbox file (child has it open now)
				fclose(mbox);
				
				// get status notification from child
				OSStatus status;
				ssize_t rc = read(notify[0], &status, sizeof(status));
				status = ntohl(status);
				switch (rc) {
					default:				// weird result of read: post error
						status = errAuthorizationToolEnvironmentError;
						// fall through
					case sizeof(status):	// read succeeded: child reported an error
						close(notify[0]);
						return status;
					case 0:					// end of file: exec succeeded
						close(notify[0]);
						return noErr;
				}
			}
				
			case 0: { // child
				// close foreign side of pipes
				close(notify[0]);
				
				// fd 1 (stdout) holds the notify write end
				dup2(notify[1], 1);
				close(notify[1]);
				
				// fd 0 (stdin) holds either the comm-link write-end or /dev/null
				close(0);
				open("/dev/null", O_RDWR);
				
				// where is the trampoline?
				const char *trampoline = "/usr/libexec/security_authtrampoline";
				char **argv = argVector(trampoline, pathToTool, mboxFdText, arguments);
				if (argv) {
					execv(trampoline, argv);
					free(argv);
				}
				
				// execute failed - tell the parent
				OSStatus error = errAuthorizationToolExecuteFailure;
				error = htonl(error);
				write(1, &error, sizeof(error));
				_exit(1);
			}
		}
	}
}

// Authorization code based on generous contribution from Allan Odgaard. Thanks, Allan!
static BOOL su_AuthorizationExecuteWithPrivilegesAndWait(AuthorizationRef authorization, const char* executablePath, AuthorizationFlags options, const char* const* arguments)
{
	// *** MUST BE SAFE TO CALL ON NON-MAIN THREAD!
	
	sig_t oldSigChildHandler = signal(SIGCHLD, SIG_DFL);
	BOOL returnValue = YES;

	if (su_AuthorizationExecuteWithPrivileges(authorization, executablePath, options, (char* const*)arguments) == errAuthorizationSuccess)
	{
		int status;
		pid_t pid = wait(&status);
		if (pid == -1 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
			returnValue = NO;
	}
	else
		returnValue = NO;
		
	signal(SIGCHLD, oldSigChildHandler);
	return returnValue;
}

@implementation SUPlainInstaller (Internals)

+ (NSURL *)_temporaryCopyURL:(NSURL *)URL didFindTrash: (BOOL*)outDidFindTrash
{
	// *** MUST BE SAFE TO CALL ON NON-MAIN THREAD!
	
	NSFileManager *fileManager = [[NSFileManager alloc] init];
	NSURL *tempURL = nil;
	
	NSError *error = nil;
	if ([URL checkResourceIsReachableAndReturnError:&error]) {
		tempURL = [fileManager URLForDirectory:NSTrashDirectory inDomain:NSUserDomainMask appropriateForURL:URL create:YES error:&error];
	}
	
	if (outDidFindTrash) {
		*outDidFindTrash = (tempURL != nil);
	}
	
	if (!tempURL) {
		tempURL = [URL URLByDeletingLastPathComponent];
	}
	
#if TRY_TO_APPEND_VERSION_NUMBER
	NSString *postFix = nil;
	NSString *version = nil;
	if ((version = [[NSBundle bundleWithURL:URL] objectForInfoDictionaryKey:@"CFBundleVersion"]) && ![version isEqualToString:@""]) {
		// We'll clean it up a little for safety.
		NSMutableCharacterSet *validCharacters = [NSMutableCharacterSet alphanumericCharacterSet];
		[validCharacters formUnionWithCharacterSet:[NSCharacterSet characterSetWithCharactersInString:@".-()"]];
		postFix = [version stringByTrimmingCharactersInSet:[validCharacters invertedSet]];
	}
	else {
		postFix = @"old";
	}
	NSString *prefix = [NSString stringWithFormat: @"%@ (%@)", [[URL lastPathComponent] stringByDeletingPathExtension], postFix];
#else
	NSString *prefix = [[path lastPathComponent] stringByDeletingPathExtension];
#endif
	NSString *tempName = [prefix stringByAppendingPathExtension: [URL pathExtension]];
	tempURL = [tempURL URLByAppendingPathComponent:tempName];
	
	
	int cnt=2;
	while ([tempURL checkResourceIsReachableAndReturnError:NULL] && cnt <= 9999) {
		tempURL = [[tempURL URLByDeletingLastPathComponent] URLByAppendingPathComponent: [NSString stringWithFormat:@"%@ %d.%@", prefix, cnt++, [URL pathExtension]]];
	}
	return tempURL;
}

+ (BOOL)_copyURLWithForcedAuthentication:(NSURL *)srcURL toURL:(NSURL *)dstURL temporaryURL:(NSURL *)tmpURL error:(NSError **)error
{
	// *** MUST BE SAFE TO CALL ON NON-MAIN THREAD!
	
	const char* srcPath = [srcURL fileSystemRepresentation];
	const char* tmpPath = [tmpURL fileSystemRepresentation];
	const char* dstPath = [dstURL fileSystemRepresentation];
	
	struct stat dstSB;
	if( stat(dstPath, &dstSB) != 0 )	// Doesn't exist yet, try containing folder.
	{
		const char *dstDirPath = [[dstURL URLByDeletingLastPathComponent] fileSystemRepresentation];
		if( stat(dstDirPath, &dstSB) != 0 )
		{
			NSString *errorMessage = [NSString stringWithFormat:@"Stat on %@ during authenticated file copy failed.", dstURL];
			if (error != NULL)
				*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUFileCopyFailure userInfo:[NSDictionary dictionaryWithObject:errorMessage forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
	}
	
	AuthorizationRef auth = NULL;
	OSStatus authStat = errAuthorizationDenied;
	while (authStat == errAuthorizationDenied) {
		authStat = AuthorizationCreate(NULL,
									   kAuthorizationEmptyEnvironment,
									   kAuthorizationFlagDefaults,
									   &auth);
	}
	
	BOOL res = NO;
	if (authStat == errAuthorizationSuccess) {
		res = YES;
		
		char uidgid[42];
		snprintf(uidgid, sizeof(uidgid), "%u:%u",
				 dstSB.st_uid, dstSB.st_gid);
		
		// If the currently-running application is trusted, the new
		// version should be trusted as well.  Remove it from the
		// quarantine to avoid a delay at launch, and to avoid
		// presenting the user with a confusing trust dialog.
		//
		// This needs to be done before "chown" changes ownership,
		// because the ownership change will fail if the file is quarantined.
		if (res)
		{
			SULog(@"releaseURLFromQuarantine");
			dispatch_sync(dispatch_get_main_queue(), ^{
				[self releaseURLFromQuarantine:srcURL];
			});
		}
		
		if( res )	// Set permissions while it's still in source, so we have it with working and correct perms when it arrives at destination.
		{
			const char* coParams[] = { "-R", uidgid, srcPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/usr/sbin/chown", kAuthorizationFlagDefaults, coParams );
			if( !res )
				SULog( @"chown -R %s %s failed.", uidgid, srcPath );
		}
		
		BOOL	haveDst = [dstURL checkResourceIsReachableAndReturnError:error];
		if( res && haveDst )	// If there's something at our tmp path (previous failed update or whatever) delete that first.
		{
			const char*	rmParams[] = { "-rf", tmpPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/bin/rm", kAuthorizationFlagDefaults, rmParams );
			if( !res )
				SULog( @"rm failed" );
		}
		
		if( res && haveDst )	// Move old exe to tmp path.
		{
			const char* mvParams[] = { "-f", dstPath, tmpPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/bin/mv", kAuthorizationFlagDefaults, mvParams );
			if( !res )
				SULog( @"mv 1 failed" );
		}
		
		if( res )	// Move new exe to old exe's path.
		{
			const char* mvParams2[] = { "-f", srcPath, dstPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/bin/mv", kAuthorizationFlagDefaults, mvParams2 );
			if( !res )
				SULog( @"mv 2 failed" );
		}
		
		//		if( res && haveDst /*&& !foundTrash*/ )	// If we managed to put the old exe in the trash, leave it there for the user to delete or recover.
		//		{									// ...  Otherwise we better delete it, wouldn't want dozens of old versions lying around next to the new one.
		//			const char* rmParams2[] = { "-rf", tmpPath, NULL };
		//			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/bin/rm", kAuthorizationFlagDefaults, rmParams2 );
		//		}
		
		AuthorizationFree(auth, 0);
		
		// If the currently-running application is trusted, the new
		// version should be trusted as well.  Remove it from the
		// quarantine to avoid a delay at launch, and to avoid
		// presenting the user with a confusing trust dialog.
		//
		// This needs to be done after the application is moved to its
		// new home with "mv" in case it's moved across filesystems: if
		// that happens, "mv" actually performs a copy and may result
		// in the application being quarantined.
        if (res)
		{
			SULog(@"releaseURLFromQuarantine after installing");
			dispatch_sync(dispatch_get_main_queue(), ^{
				[self releaseURLFromQuarantine:dstURL];
			});
		}
		
		if (!res)
		{
			// Something went wrong somewhere along the way, but we're not sure exactly where.
			NSString *errorMessage = [NSString stringWithFormat:@"Authenticated file copy from %@ to %@ failed.", srcURL, dstURL];
			if (error != nil)
				*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUAuthenticationFailure userInfo:[NSDictionary dictionaryWithObject:errorMessage forKey:NSLocalizedDescriptionKey]];
		}
	}
	else
	{
		if (error != nil)
			*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUAuthenticationFailure userInfo:[NSDictionary dictionaryWithObject:@"Couldn't get permission to authenticate." forKey:NSLocalizedDescriptionKey]];
	}
	return res;
}

+ (BOOL)_moveURLWithForcedAuthentication:(NSURL *)srcURL toURL:(NSURL *)dstURL error:(NSError **)error
{
	// *** MUST BE SAFE TO CALL ON NON-MAIN THREAD!
	
	const char* srcPath = [srcURL fileSystemRepresentation];
	const char* dstPath = [dstURL fileSystemRepresentation];
	const char* dstContainerPath = [[dstURL URLByDeletingLastPathComponent] fileSystemRepresentation];
	
	struct stat dstSB;
	stat(dstContainerPath, &dstSB);
	
	AuthorizationRef auth = NULL;
	OSStatus authStat = errAuthorizationDenied;
	while( authStat == errAuthorizationDenied )
	{
		authStat = AuthorizationCreate(NULL,
									   kAuthorizationEmptyEnvironment,
									   kAuthorizationFlagDefaults,
									   &auth);
	}
	
	BOOL res = NO;
	if (authStat == errAuthorizationSuccess)
	{
		res = YES;
		
		char uidgid[42];
		snprintf(uidgid, sizeof(uidgid), "%d:%d",
				 dstSB.st_uid, dstSB.st_gid);
		
		if( res )	// Set permissions while it's still in source, so we have it with working and correct perms when it arrives at destination.
		{
			const char* coParams[] = { "-R", uidgid, srcPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/usr/sbin/chown", kAuthorizationFlagDefaults, coParams );
			if( !res )
				SULog(@"Can't set permissions");
		}
		
		BOOL	haveDst = [dstURL checkResourceIsReachableAndReturnError:error];
		if( res && haveDst )	// If there's something at our tmp path (previous failed update or whatever) delete that first.
		{
			const char*	rmParams[] = { "-rf", dstPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/bin/rm", kAuthorizationFlagDefaults, rmParams );
			if( !res )
				SULog(@"Can't remove destination file");
		}
		
		if( res )	// Move!.
		{
			const char* mvParams[] = { "-f", srcPath, dstPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/bin/mv", kAuthorizationFlagDefaults, mvParams );
			if( !res )
				SULog(@"Can't move source file");
		}
		
		AuthorizationFree(auth, 0);
		
		if (!res)
		{
			// Something went wrong somewhere along the way, but we're not sure exactly where.
			NSString *errorMessage = [NSString stringWithFormat:@"Authenticated file move from %@ to %@ failed.", srcURL, dstURL];
			if (error != NULL)
				*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUAuthenticationFailure userInfo:[NSDictionary dictionaryWithObject:errorMessage forKey:NSLocalizedDescriptionKey]];
		}
	}
	else
	{
		if (error != NULL)
			*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUAuthenticationFailure userInfo:[NSDictionary dictionaryWithObject:@"Couldn't get permission to authenticate." forKey:NSLocalizedDescriptionKey]];
	}
	return res;
}

+ (BOOL)_removeItemAtURLWithForcedAuthentication:(NSURL *)srcURL error:(NSError **)error
{
	// *** MUST BE SAFE TO CALL ON NON-MAIN THREAD!
	const char *srcPath = [srcURL fileSystemRepresentation];
	
	AuthorizationRef auth = NULL;
	OSStatus authStat = errAuthorizationDenied;
	while( authStat == errAuthorizationDenied )
	{
		authStat = AuthorizationCreate(NULL,
									   kAuthorizationEmptyEnvironment,
									   kAuthorizationFlagDefaults,
									   &auth);
	}
	
	BOOL res = NO;
	if (authStat == errAuthorizationSuccess)
	{
		res = YES;
		
		if( res )	// If there's something at our tmp path (previous failed update or whatever) delete that first.
		{
			const char*	rmParams[] = { "-rf", srcPath, NULL };
			res = su_AuthorizationExecuteWithPrivilegesAndWait( auth, "/bin/rm", kAuthorizationFlagDefaults, rmParams );
			if( !res )
				SULog(@"Can't remove destination file");
		}
		
		AuthorizationFree(auth, 0);
		
		if (!res)
		{
			// Something went wrong somewhere along the way, but we're not sure exactly where.
			NSString *errorMessage = [NSString stringWithFormat:@"Authenticated file remove from %s failed.", srcPath];
			if (error != NULL)
				*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUAuthenticationFailure userInfo:[NSDictionary dictionaryWithObject:errorMessage forKey:NSLocalizedDescriptionKey]];
		}
	}
	else
	{
		if (error != NULL)
			*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUAuthenticationFailure userInfo:[NSDictionary dictionaryWithObject:@"Couldn't get permission to authenticate." forKey:NSLocalizedDescriptionKey]];
	}
	return res;
}

+ (BOOL)_removeItemAtURL:(NSURL *)URL error:(NSError *__autoreleasing *)error
{
	BOOL	success = YES;
	if (![[NSFileManager defaultManager] removeItemAtURL: URL error: NULL] )
	{
		success = [self _removeItemAtURLWithForcedAuthentication: URL error: error];
	}
	return success;
}

+ (void)_moveItemAtURLToTrash:(NSURL *)URL
{
	[[NSWorkspace sharedWorkspace] recycleURLs:@[URL] completionHandler:^(NSDictionary *newURLs, NSError *error) {
		if (error) {
			BOOL		didFindTrash = NO;
			NSURL *trashURL = [self _temporaryCopyURL:URL didFindTrash:&didFindTrash];
			if (didFindTrash) {
				NSError		*err = nil;
				if( ![self _moveURLWithForcedAuthentication: URL toURL: trashURL error: &err] )
					SULog(@"Sparkle error: couldn't move %@ to the trash (%@). %@", URL, trashURL, err);
			} else {
				SULog(@"Sparkle error: couldn't move %@ to the trash. This is often a sign of a permissions error.", URL);
			}
		}
	}];
}

+ (BOOL)copyURLWithAuthentication:(NSURL *)srcURL overURL:(NSURL *)dstURL error:(NSError **)error
{
	BOOL		hadFileAtDest = NO, didFindTrash = NO;
	NSFileManager *fileManager = [[NSFileManager alloc] init];
	NSURL	*tmpURL = [self _temporaryCopyURL: dstURL didFindTrash: &didFindTrash];
	
	// Make ref for destination:
	hadFileAtDest = (srcURL.fileReferenceURL != nil);	// There is a file at the destination, move it aside. If we normalized the name, we might not get here, so don't error.
	if ( hadFileAtDest )
	{
		if (0 != access([dstURL fileSystemRepresentation], W_OK) || 0 != access([[dstURL URLByDeletingLastPathComponent] fileSystemRepresentation], W_OK))
		{
			return [self _copyURLWithForcedAuthentication:srcURL toURL:dstURL temporaryURL:tmpURL error:error];
		}
	}
	else
	{
		if (0 != access([[dstURL URLByDeletingLastPathComponent] fileSystemRepresentation], W_OK)
			|| 0 != access([[[dstURL URLByDeletingLastPathComponent] URLByDeletingLastPathComponent] fileSystemRepresentation], W_OK))
		{
			return [self _copyURLWithForcedAuthentication:srcURL toURL:dstURL temporaryURL:tmpURL error:error];
		}
	}
	
	if (hadFileAtDest)
	{
		if (![[tmpURL URLByDeletingLastPathComponent] checkResourceIsReachableAndReturnError:error]) {
			tmpURL = [dstURL URLByDeletingLastPathComponent];
		}
	}
	
	if ([[dstURL URLByDeletingLastPathComponent] checkResourceIsReachableAndReturnError:error] && hadFileAtDest)
	{
		BOOL success = [fileManager moveItemAtURL:dstURL toURL:tmpURL error:error];
		if (!success && hadFileAtDest)
		{
			if (error != NULL)
				*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUFileCopyFailure userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Couldn't move %@ to %@.", dstURL, tmpURL] forKey:NSLocalizedDescriptionKey]];
			return NO;
		}
		
	}
	
	if ([srcURL checkResourceIsReachableAndReturnError:error]) {
		BOOL success = [fileManager copyItemAtURL:srcURL toURL:dstURL error:error];
		if (!success)
		{
			// We better move the old version back to its old location
			if( hadFileAtDest )
				[fileManager moveItemAtURL:tmpURL toURL:dstURL error:error];
			
			if (error != NULL)
				*error = [NSError errorWithDomain:SUSparkleErrorDomain code:SUFileCopyFailure userInfo:[NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"Couldn't move %@ to %@.", dstURL, tmpURL] forKey:NSLocalizedDescriptionKey]];
			
			return NO;
			
		}
	}
	
	// If the currently-running application is trusted, the new
	// version should be trusted as well.  Remove it from the
	// quarantine to avoid a delay at launch, and to avoid
	// presenting the user with a confusing trust dialog.
	//
	// This needs to be done after the application is moved to its
	// new home in case it's moved across filesystems: if that
	// happens, the move is actually a copy, and it may result
	// in the application being quarantined.
	dispatch_sync(dispatch_get_main_queue(), ^{
		[self releaseURLFromQuarantine:dstURL];
	});
	
	return YES;
}

@end

#import <dlfcn.h>
#import <errno.h>
#import <sys/xattr.h>

@implementation SUPlainInstaller (MMExtendedAttributes)

+ (int)removeXAttr:(const char*)name
          fromURL:(NSURL *)file
           options:(int)options
{
	// *** MUST BE SAFE TO CALL ON NON-MAIN THREAD!
	
	const char* path = NULL;
	@try {
		path = [file fileSystemRepresentation];
	}
	@catch (id exception) {
		// -[NSString fileSystemRepresentation] throws an exception if it's
		// unable to convert the string to something suitable.  Map that to
		// EDOM, "argument out of domain", which sort of conveys that there
		// was a conversion failure.
		errno = EDOM;
		return -1;
	}
	
	return removexattr(path, name, options);
}

/**
 Removes the directory tree rooted at |root| from the file quarantine.
 The quarantine was introduced on Mac OS X 10.5 and is described at:
   http://developer.apple.com/releasenotes/Carbon/RN-LaunchServices/index.html#apple_ref/doc/uid/TP40001369-DontLinkElementID_2
 
 If |root| is not a directory, then it alone is removed from the quarantine.
 Symbolic links, including |root| if it is a symbolic link, will not be
 traversed.
 
 Ordinarily, the quarantine is managed by calling LSSetItemAttribute
 to set the kLSItemQuarantineProperties attribute to a dictionary specifying
 the quarantine properties to be applied.  However, it does not appear to be
 possible to remove an item from the quarantine directly through any public
 Launch Services calls.  Instead, this method takes advantage of the fact
 that the quarantine is implemented in part by setting an extended attribute,
 "com.apple.quarantine", on affected files.  Removing this attribute is
 sufficient to remove files from the quarantine.
 */

+ (void)releaseURLFromQuarantine:(NSURL*)URL
{
	// *** MUST BE SAFE TO CALL ON NON-MAIN THREAD!
	
	const char* quarantineAttribute = "com.apple.quarantine";
	const int removeXAttrOptions = XATTR_NOFOLLOW;
	
	[self removeXAttr:quarantineAttribute
			  fromURL:URL
			  options:removeXAttrOptions];
	
	// Only recurse if it's actually a directory.  Don't recurse into a
	// root-level symbolic link.
	NSNumber *isDirectory = nil;
	if ([URL getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:NULL]) {
		if ([isDirectory boolValue]) {
			// The NSDirectoryEnumerator will avoid recursing into any contained
			// symbolic links, so no further type checks are needed.
			NSDirectoryEnumerator *directoryEnumerator = [[NSFileManager defaultManager] enumeratorAtURL:URL includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:NULL];
			for (NSURL *subURL in directoryEnumerator) {
				[self removeXAttr:quarantineAttribute fromURL:subURL options:removeXAttrOptions];
			}
		}
	}
}

@end
