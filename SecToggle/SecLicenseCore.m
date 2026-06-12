#import "SecLicenseCore.h"

#import <CommonCrypto/CommonCrypto.h>

NSString * const kSecLicenseDefaultSecret = @"SecToggle-License-2026-ChangeMe";

static NSString *SecLicenseFormatGroups(NSString *hex16) {
    NSString *h = [[hex16 uppercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    if (h.length < 16) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < 16; i += 4) {
        [parts addObject:[h substringWithRange:NSMakeRange(i, 4)]];
    }
    return [parts componentsJoinedByString:@"-"];
}

static NSData *SecLicenseHMAC(NSString *uuid, NSString *secret) {
    const char *key = [secret UTF8String];
    const char *msg = [uuid UTF8String];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), msg, strlen(msg), mac);
    return [NSData dataWithBytes:mac length:CC_SHA256_DIGEST_LENGTH];
}

NSString *SecLicenseNormalizeUUID(NSString *raw) {
    if (!raw.length) return nil;
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"] invertedSet];
    if ([raw rangeOfCharacterFromSet:nonHex].location != NSNotFound) {
        NSString *compact = [[raw lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        compact = [[compact componentsSeparatedByCharactersInSet:nonHex] componentsJoinedByString:@""];
        if (compact.length != 32) return nil;
        return [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                [compact substringWithRange:NSMakeRange(0, 8)],
                [compact substringWithRange:NSMakeRange(8, 4)],
                [compact substringWithRange:NSMakeRange(12, 4)],
                [compact substringWithRange:NSMakeRange(16, 4)],
                [compact substringWithRange:NSMakeRange(20, 12)]];
    }
    NSString *s = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (s.length != 36) return nil;
    return s;
}

NSString *SecLicenseDeviceCodeShort(NSString *uuid) {
    NSString *norm = SecLicenseNormalizeUUID(uuid);
    if (!norm) return nil;
    NSData *data = [norm dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:12];
    for (int i = 0; i < 6; i++) {
        [hex appendFormat:@"%02X", digest[i]];
    }
    return SecLicenseFormatGroups(hex);
}

NSString *SecLicenseGenerateCode(NSString *uuid, NSString *secret) {
    NSString *norm = SecLicenseNormalizeUUID(uuid);
    if (!norm || !secret.length) return nil;
    NSData *mac = SecLicenseHMAC(norm, secret);
    const unsigned char *bytes = mac.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
    }
    return SecLicenseFormatGroups(hex);
}

BOOL SecLicenseVerify(NSString *uuid, NSString *code, NSString *secret) {
    NSString *expected = SecLicenseGenerateCode(uuid, secret);
    if (!expected.length) return NO;
    NSString *got = SecLicenseFormatGroups(code);
    if (got.length != expected.length) return NO;
    return [expected isEqualToString:got];
}
