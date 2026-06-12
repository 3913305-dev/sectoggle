#import "SecDeviceID.h"
#import "SecLicenseCore.h"

#import <Security/Security.h>
#import <UIKit/UIKit.h>

static NSString * const kSecDeviceService = @"com.sectoggle.license";
static NSString * const kSecDeviceAccount = @"device_uuid";
static NSString * const kSecActivationAccount = @"activation_code";

@implementation SecDeviceID

+ (NSString *)keychainDeviceUUID {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kSecDeviceService,
        (__bridge id)kSecAttrAccount: kSecDeviceAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        NSString *uuid = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (uuid.length) return uuid;
    }
    NSString *newUUID = [[NSUUID UUID] UUIDString].lowercaseString;
    NSData *payload = [newUUID dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *add = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kSecDeviceService,
        (__bridge id)kSecAttrAccount: kSecDeviceAccount,
        (__bridge id)kSecValueData: payload,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    SecItemDelete((__bridge CFDictionaryRef)add);
    status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status != errSecSuccess) return newUUID;
    return newUUID;
}

+ (NSString *)identifierForVendor {
    return [[[UIDevice currentDevice] identifierForVendor] UUIDString] ?: @"—";
}

+ (BOOL)saveActivationCode:(NSString *)code {
    if (!code.length) return NO;
    NSData *payload = [code dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kSecDeviceService,
        (__bridge id)kSecAttrAccount: kSecActivationAccount,
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    NSDictionary *add = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kSecDeviceService,
        (__bridge id)kSecAttrAccount: kSecActivationAccount,
        (__bridge id)kSecValueData: payload,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    return SecItemAdd((__bridge CFDictionaryRef)add, NULL) == errSecSuccess;
}

+ (NSString *)savedActivationCode {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kSecDeviceService,
        (__bridge id)kSecAttrAccount: kSecActivationAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) {
        return nil;
    }
    NSData *data = (__bridge_transfer NSData *)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (NSString *)licenseExpiryDisplay {
    NSString *code = [self savedActivationCode];
    if (!code.length) return @"—";
    return SecLicenseExpiryDisplay(SecLicenseExpiryFromCode(code));
}

+ (BOOL)isLicensed {
    NSString *uuid = [self keychainDeviceUUID];
    NSString *code = [self savedActivationCode];
    if (!code.length) return NO;
    return SecLicenseVerify(uuid, code, kSecLicenseDefaultSecret);
}

@end
