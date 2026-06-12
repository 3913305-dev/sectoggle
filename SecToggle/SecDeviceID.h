#import <UIKit/UIKit.h>

@interface SecDeviceID : NSObject
+ (NSString *)keychainDeviceUUID;
+ (NSString *)identifierForVendor;
+ (BOOL)saveActivationCode:(NSString *)code;
+ (NSString *)savedActivationCode;
+ (NSString *)licenseExpiryDisplay;
+ (BOOL)isLicensed;
@end
