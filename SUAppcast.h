//
//  SUAppcast.h
//  Sparkle
//
//  Created by Andy Matuschak on 3/12/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//

#ifndef SUAPPCAST_H
#define SUAPPCAST_H

@class SUAppcast, SUAppcastItem;

@protocol SUAppcastDelegate <NSObject>

@optional

- (void)appcastDidFinishLoading:(SUAppcast *)appcast;
- (void)appcast:(SUAppcast *)appcast failedToLoadWithError:(NSError *)error;

@end

@interface SUAppcast : NSObject
{
@private
	NSArray *items;
	NSString *downloadFilename;
	NSURLDownload *download;
}

@property (nonatomic, weak) id <SUAppcastDelegate> delegate;
@property (nonatomic, copy) NSString *userAgentString;

- (void)fetchAppcastFromURL:(NSURL *)url;

- (NSArray *)items;

@end

#endif
