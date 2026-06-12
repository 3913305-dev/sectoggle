#import "ViewController.h"
#import "SecDeviceID.h"
#import "SecLicenseCore.h"

#import <Security/Security.h>

@interface ViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *uuidLabel;
@property (nonatomic, strong) UILabel *shortLabel;
@property (nonatomic, strong) UILabel *idfvLabel;
@property (nonatomic, strong) UITextField *codeField;
@property (nonatomic, copy) NSString *deviceUUID;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"SecLicense";

    self.deviceUUID = [SecDeviceID keychainDeviceUUID];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];

    self.statusLabel = [self makeLabel:@"" font:[UIFont boldSystemFontOfSize:17] color:[UIColor labelColor]];
    self.uuidLabel = [self makeLabel:self.deviceUUID font:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular] color:[UIColor secondaryLabelColor]];
    self.uuidLabel.numberOfLines = 0;

    NSString *shortCode = SecLicenseDeviceCodeShort(self.deviceUUID) ?: @"—";
    self.shortLabel = [self makeLabel:shortCode font:[UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightMedium] color:[UIColor labelColor]];

    NSString *idfv = [SecDeviceID identifierForVendor];
    self.idfvLabel = [self makeLabel:idfv font:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular] color:[UIColor tertiaryLabelColor]];
    self.idfvLabel.numberOfLines = 0;

    [stack addArrangedSubview:[self sectionTitle:@"授权状态"]];
    [stack addArrangedSubview:self.statusLabel];
    [stack addArrangedSubview:[self sectionTitle:@"设备 UUID（发码用，复制给管理员）"]];
    [stack addArrangedSubview:self.uuidLabel];
    [stack addArrangedSubview:[self copyButton:@"复制 UUID" action:@selector(copyUUID)]];
    [stack addArrangedSubview:[self sectionTitle:@"短码核对"]];
    [stack addArrangedSubview:self.shortLabel];
    [stack addArrangedSubview:[self sectionTitle:@"IDFV（参考，抹机会变）"]];
    [stack addArrangedSubview:self.idfvLabel];
    [stack addArrangedSubview:[self sectionTitle:@"激活码"]];

    self.codeField = [[UITextField alloc] init];
    self.codeField.borderStyle = UITextBorderStyleRoundedRect;
    self.codeField.placeholder = @"XXXX-XXXX-XXXX-XXXX";
    self.codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.codeField.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular];
    NSString *saved = [SecDeviceID savedActivationCode];
    if (saved.length) self.codeField.text = saved;
    [stack addArrangedSubview:self.codeField];

    UIStackView *btnRow = [[UIStackView alloc] init];
    btnRow.axis = UILayoutConstraintAxisHorizontal;
    btnRow.spacing = 10;
    btnRow.distribution = UIStackViewDistributionFillEqually;
    [btnRow addArrangedSubview:[self actionButton:@"保存并校验" action:@selector(saveAndVerify)]];
    [btnRow addArrangedSubview:[self actionButton:@"清除授权" action:@selector(clearLicense)]];
    [stack addArrangedSubview:btnRow];

    UILabel *hint = [self makeLabel:@"抹机或删 App 后 Keychain UUID 可能变化，需重新发码。" font:[UIFont systemFontOfSize:12] color:[UIColor secondaryLabelColor]];
    hint.numberOfLines = 0;
    [stack addArrangedSubview:hint];

    [self refreshStatus];
}

- (UILabel *)sectionTitle:(NSString *)text {
    return [self makeLabel:text font:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold] color:[UIColor secondaryLabelColor]];
}

- (UILabel *)makeLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = font;
    l.textColor = color;
    return l;
}

- (UIButton *)copyButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)actionButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = [UIColor secondarySystemFillColor];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(10, 8, 10, 8);
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refreshStatus {
    if ([SecDeviceID isLicensed]) {
        self.statusLabel.text = @"已授权 ✓";
        self.statusLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.statusLabel.text = @"未授权";
        self.statusLabel.textColor = [UIColor systemOrangeColor];
    }
}

- (void)copyUUID {
    UIPasteboard.generalPasteboard.string = self.deviceUUID;
    [self flash:@"已复制 UUID"];
}

- (void)saveAndVerify {
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!code.length) {
        [self alert:@"请输入激活码"];
        return;
    }
    if (!SecLicenseVerify(self.deviceUUID, code, kSecLicenseDefaultSecret)) {
        [self alert:@"激活码无效，请核对 UUID 与发码密钥"];
        return;
    }
    NSString *formatted = SecLicenseGenerateCode(self.deviceUUID, kSecLicenseDefaultSecret);
    [SecDeviceID saveActivationCode:formatted];
    self.codeField.text = formatted;
    [self refreshStatus];
    [self flash:@"授权成功"];
}

- (void)clearLicense {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: @"com.sectoggle.license",
        (__bridge id)kSecAttrAccount: @"activation_code",
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
    self.codeField.text = @"";
    [self refreshStatus];
    [self flash:@"已清除"];
}

- (void)flash:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [a dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)alert:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"提示" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
