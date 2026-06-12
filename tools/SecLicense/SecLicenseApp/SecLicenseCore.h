#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString * const kSecLicenseDefaultSecret;

NSString *SecLicenseNormalizeUUID(NSString *raw);
NSString *SecLicenseDeviceCodeShort(NSString *uuid);
NSString *SecLicenseCanonicalCode(NSString *raw);
NSString *SecLicenseExpiryFromCode(NSString *code);
NSString *SecLicenseExpiryDisplay(NSString *yyyymmdd);
BOOL SecLicenseIsExpired(NSString *yyyymmdd);
NSString *SecLicenseExpiryFromDays(NSInteger days);
NSString *SecLicenseGenerateCodeWithExpiry(NSString *uuid, NSString *secret, NSString *expiryYYYYMMDD);
NSString *SecLicenseGenerateCode(NSString *uuid, NSString *secret);
BOOL SecLicenseVerify(NSString *uuid, NSString *code, NSString *secret);
