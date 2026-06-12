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

static NSData *SecLicenseHMAC(NSString *message, NSString *secret) {
    const char *key = [secret UTF8String];
    const char *msg = [message UTF8String];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), msg, strlen(msg), mac);
    return [NSData dataWithBytes:mac length:CC_SHA256_DIGEST_LENGTH];
}

static BOOL SecLicenseValidExpiry(NSString *yyyymmdd) {
    if (yyyymmdd.length != 8) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([yyyymmdd rangeOfCharacterFromSet:[digits invertedSet]].location != NSNotFound) return NO;
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    return [f dateFromString:yyyymmdd] != nil;
}

static NSString *SecLicenseCompactHex(NSString *raw) {
    NSMutableString *s = [NSMutableString string];
    NSString *upper = [raw uppercaseString];
    for (NSUInteger i = 0; i < upper.length; i++) {
        unichar c = [upper characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')) {
            [s appendFormat:@"%C", c];
        }
    }
    return s;
}

static BOOL SecLicenseParseCode(NSString *raw, NSString **outHex16, NSString **outExpiry) {
    if (outHex16) *outHex16 = nil;
    if (outExpiry) *outExpiry = nil;
    if (!raw.length) return NO;

    NSString *compact = SecLicenseCompactHex(raw);
    if (compact.length == 16) {
        if (outHex16) *outHex16 = compact;
        return YES;
    }
    if (compact.length == 24) {
        NSString *hex = [compact substringToIndex:16];
        NSString *expiry = [compact substringFromIndex:16];
        if (SecLicenseValidExpiry(expiry)) {
            if (outHex16) *outHex16 = hex;
            if (outExpiry) *outExpiry = expiry;
            return YES;
        }
    }

    NSArray *parts = [[raw uppercaseString] componentsSeparatedByString:@"-"];
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (t.length) [clean addObject:t];
    }

    if (clean.count == 4) {
        NSString *hex = [[clean componentsJoinedByString:@""] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        if (hex.length != 16) return NO;
        if (outHex16) *outHex16 = hex;
        return YES;
    }
    if (clean.count == 5) {
        NSString *hex = [[[clean subarrayWithRange:NSMakeRange(0, 4)] componentsJoinedByString:@""]
                         stringByReplacingOccurrencesOfString:@"-" withString:@""];
        NSString *expiry = clean[4];
        if (hex.length != 16 || !SecLicenseValidExpiry(expiry)) return NO;
        if (outHex16) *outHex16 = hex;
        if (outExpiry) *outExpiry = expiry;
        return YES;
    }
    return NO;
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
    return [NSString stringWithFormat:@"%@-%@-%@",
            [hex substringWithRange:NSMakeRange(0, 4)],
            [hex substringWithRange:NSMakeRange(4, 4)],
            [hex substringWithRange:NSMakeRange(8, 4)]];
}

NSString *SecLicenseCanonicalCode(NSString *raw) {
    NSString *hex = nil;
    NSString *expiry = nil;
    if (!SecLicenseParseCode(raw, &hex, &expiry)) return nil;
    NSString *base = SecLicenseFormatGroups(hex);
    if (!base.length) return nil;
    return expiry.length ? [NSString stringWithFormat:@"%@-%@", base, expiry] : base;
}

NSString *SecLicenseExpiryFromCode(NSString *code) {
    NSString *expiry = nil;
    if (!SecLicenseParseCode(code, NULL, &expiry)) return nil;
    return expiry;
}

NSString *SecLicenseExpiryDisplay(NSString *yyyymmdd) {
    if (!yyyymmdd.length) return @"永久";
    if (yyyymmdd.length != 8) return yyyymmdd;
    return [NSString stringWithFormat:@"%@-%@-%@",
            [yyyymmdd substringWithRange:NSMakeRange(0, 4)],
            [yyyymmdd substringWithRange:NSMakeRange(4, 2)],
            [yyyymmdd substringWithRange:NSMakeRange(6, 2)]];
}

BOOL SecLicenseIsExpired(NSString *yyyymmdd) {
    if (!yyyymmdd.length) return NO;
    if (!SecLicenseValidExpiry(yyyymmdd)) return YES;
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone localTimeZone];
    NSDate *day = [f dateFromString:yyyymmdd];
    if (!day) return YES;
    NSDate *end = [day dateByAddingTimeInterval:86400.0 - 1.0];
    return [[NSDate date] compare:end] == NSOrderedDescending;
}

NSString *SecLicenseExpiryFromDays(NSInteger days) {
    if (days < 1) days = 1;
    NSDate *date = [[NSDate date] dateByAddingTimeInterval:(NSTimeInterval)days * 86400.0];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone localTimeZone];
    return [f stringFromDate:date];
}

NSString *SecLicenseGenerateCodeWithExpiry(NSString *uuid, NSString *secret, NSString *expiryYYYYMMDD) {
    NSString *norm = SecLicenseNormalizeUUID(uuid);
    if (!norm || !secret.length || !SecLicenseValidExpiry(expiryYYYYMMDD)) return nil;
    NSString *payload = [NSString stringWithFormat:@"%@|%@", norm, expiryYYYYMMDD];
    NSData *mac = SecLicenseHMAC(payload, secret);
    const unsigned char *bytes = mac.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) {
        [hex appendFormat:@"%02X", bytes[i]];
    }
    return [NSString stringWithFormat:@"%@-%@", SecLicenseFormatGroups(hex), expiryYYYYMMDD];
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
    NSString *norm = SecLicenseNormalizeUUID(uuid);
    if (!norm || !secret.length) return NO;

    NSString *hex = nil;
    NSString *expiry = nil;
    if (!SecLicenseParseCode(code, &hex, &expiry)) return NO;

    if (expiry.length) {
        if (SecLicenseIsExpired(expiry)) return NO;
        NSString *payload = [NSString stringWithFormat:@"%@|%@", norm, expiry];
        NSData *mac = SecLicenseHMAC(payload, secret);
        const unsigned char *bytes = mac.bytes;
        NSMutableString *expected = [NSMutableString stringWithCapacity:16];
        for (int i = 0; i < 8; i++) {
            [expected appendFormat:@"%02X", bytes[i]];
        }
        return [SecLicenseFormatGroups(expected) isEqualToString:SecLicenseFormatGroups(hex)];
    }

    NSData *mac = SecLicenseHMAC(norm, secret);
    const unsigned char *bytes = mac.bytes;
    NSMutableString *expected = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) {
        [expected appendFormat:@"%02X", bytes[i]];
    }
    return [SecLicenseFormatGroups(expected) isEqualToString:SecLicenseFormatGroups(hex)];
}
