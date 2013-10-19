//
//  SUDSAVerifier.m
//  Sparkle
//
//  Created by Andy Matuschak on 3/16/06.
//  Copyright 2006 Andy Matuschak. All rights reserved.
//
//  Re-created by Zach Waldowski on 10/18/13.
//  Copyright (c) 2013 Big Nerd Ranch. All rights reserved.
//
//  Includes code from Plop by Mark Hamlin.
//  Copyright (c) 2011 Mark Hamlin. All rights reserved.
//

#import "SUDSAVerifier.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>

@implementation SUDSAVerifier

+ (BOOL)validatePath:(NSString *)path withEncodedDSASignature:(NSString *)encodedSignature withPublicDSAKey:(NSString *)pkeyString
{
	if (!encodedSignature || !pkeyString || !path) return NO;
	
	SUDSAVerifier *verifier = [[self alloc] initWithPublicKeyString:pkeyString];
	
	if (!verifier) {
		return NO;
	}
	
	encodedSignature = [encodedSignature stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	NSData *signatureData = [[NSData alloc] initWithBase64Encoding:encodedSignature];
	
	return [verifier verifySignature:signatureData ofItemAtPath:path];
}

- (instancetype)initWithPublicKeyString:(NSString *)string
{
	NSData *keyData = [string dataUsingEncoding:NSUTF8StringEncoding];
	return (self = [self initWithPublicKey:keyData]);
}

- (instancetype)initWithPublicKey:(NSData *)data
{
	CFArrayRef items = NULL;
    
    id(^cleanup)(void) = ^id{
        if (items) {
            CFRelease(items);
        }
		
		return nil;
    };
    
	SecItemImportExportKeyParameters params = {};
    SecExternalFormat format = kSecFormatOpenSSL;
    SecExternalItemType itemType = kSecItemTypePublicKey;
    
    OSStatus status = SecItemImport((__bridge CFDataRef)data, NULL, &format, &itemType, 0, &params, NULL, &items);
    
    if (status || format != kSecFormatOpenSSL || itemType != kSecItemTypePublicKey || !items || CFArrayGetCount(items) != 1) {
        return cleanup();
    }
	
	self = [super init];
	if (self) {
		_publicKey = (SecKeyRef)CFRetain(CFArrayGetValueAtIndex(items, 0));
		cleanup();
	}
	return self;
}

- (void)dealloc
{
	if (_publicKey) {
		CFRelease(_publicKey);
	}
}

- (BOOL)verifySignature:(NSData *)signature ofItemAtPath:(NSString *)path
{
	NSInputStream *dataInputStream = [NSInputStream inputStreamWithFileAtPath:path];
	return [self verifySignature:signature withStream:dataInputStream];
}

- (BOOL)verifySignature:(NSData *)signature withStream:(NSInputStream *)stream
{
	if (!signature || !stream) {
		return NO;
	}
    
    SecGroupTransformRef group = SecTransformCreateGroupTransform();
    SecTransformRef dataReadTransform = NULL;
    SecTransformRef dataDigestTransform = NULL;
    SecTransformRef dataVerifyTransform = NULL;
	CFErrorRef error = NULL;
    
    BOOL(^cleanupBlock) () = ^{
        if (group) {
            CFRelease(group);
        }
        
        if (dataReadTransform) {
            CFRelease(dataReadTransform);
        }
		
		if (dataDigestTransform) {
			CFRelease(dataDigestTransform);
		}
		
        if (dataVerifyTransform) {
            CFRelease(dataVerifyTransform);
        }
		
		if (error) {
			CFRelease(error);
		}
		
		return NO;
    };
	
	dataReadTransform = SecTransformCreateReadTransformWithReadStream((__bridge CFReadStreamRef)stream);
    if (!dataReadTransform) { return cleanupBlock(); }
	
	dataDigestTransform = SecDigestTransformCreate(kSecDigestSHA1, CC_SHA1_DIGEST_LENGTH, NULL);
	if (!dataDigestTransform) { return cleanupBlock(); }
	
	dataVerifyTransform = SecVerifyTransformCreate(self.publicKey, (__bridge CFDataRef)signature, NULL);
    if (!dataVerifyTransform) { return cleanupBlock(); }
	
	SecTransformConnectTransforms(dataReadTransform, kSecTransformOutputAttributeName, dataDigestTransform, kSecTransformInputAttributeName, group, &error);
	if (error) { return cleanupBlock(); }
	SecTransformConnectTransforms(dataDigestTransform, kSecTransformOutputAttributeName, dataVerifyTransform, kSecTransformInputAttributeName, group, &error);
	if (error) { return cleanupBlock(); }
	
	CFBooleanRef transformResult = SecTransformExecute(group, NULL);
	
	cleanupBlock();
	
	if (transformResult) {
		return [(__bridge_transfer NSNumber *)transformResult boolValue];
	}
	
	return NO;
}

@end
