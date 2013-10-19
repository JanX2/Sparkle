//
//  SUDSAVerifier.h
//  Sparkle
//
//  Created by Zach Waldowski on 10/18/13.
//  Copyright (c) 2013 Big Nerd Ranch. All rights reserved.
//
//  Includes code from Plop by Mark Hamlin.
//  Copyright (c) 2011 Mark Hamlin. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface SUDSAVerifier : NSObject

+ (BOOL)validatePath:(NSString *)path withEncodedDSASignature:(NSString *)encodedSignature withPublicDSAKey:(NSString *)pkeyString;

- (instancetype)initWithPublicKeyString:(NSString *)string;
- (instancetype)initWithPublicKey:(NSData *)data;

@property (nonatomic, readonly) SecKeyRef publicKey;

- (BOOL)verifySignature:(NSData *)signature ofItemAtPath:(NSString *)path;
- (BOOL)verifySignature:(NSData *)signature withStream:(NSInputStream *)stream;

@end
