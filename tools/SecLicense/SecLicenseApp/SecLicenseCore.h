#import <Foundation/Foundation.h>

#import <CommonCrypto/CommonCrypto.h>

FOUNDATION_EXPORT NSString * const kSecLicenseDefaultSecret;

NSString *SecLicenseNormalizeUUID(NSString *raw);
NSString *SecLicenseDeviceCodeShort(NSString *uuid);
NSString *SecLicenseGenerateCode(NSString *uuid, NSString *secret);
BOOL SecLicenseVerify(NSString *uuid, NSString *code, NSString *secret);
