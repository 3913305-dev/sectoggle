#import <UIKit/UIKit.h>

@interface SecDeviceID : NSObject
+ (NSString *)keychainDeviceUUID;
+ (NSString *)identifierForVendor;
+ (BOOL)saveActivationCode:(NSString *)code;
+ (NSString *)savedActivationCode;
+ (BOOL)isLicensed;
@end
