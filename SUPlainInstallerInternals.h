//
//  SUPlainInstallerInternals.m
//  Sparkle
//
//  Created by Andy Matuschak on 3/9/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#ifndef SUPLAININSTALLERINTERNALS_H
#define SUPLAININSTALLERINTERNALS_H

#import "SUPlainInstaller.h"

@interface SUPlainInstaller (Internals)

+ (BOOL)copyURLWithAuthentication:(NSURL *)srcURL overURL:(NSURL *)dstURL error:(NSError **)error;
+ (void)_moveItemAtURLToTrash:(NSURL *)URL;
+ (BOOL)_removeItemAtURL:(NSURL *)URL error: (NSError**)error;

@end

#endif
