#import "IssueViewController.h"
#import "SecLicenseCore.h"

@interface IssueViewController ()
@property (nonatomic, strong) UITextField *uuidField;
@property (nonatomic, strong) UITextField *daysField;
@property (nonatomic, strong) UILabel *expiryPreviewLabel;
@property (nonatomic, strong) UILabel *shortLabel;
@property (nonatomic, strong) UILabel *codeLabel;
@end

@implementation IssueViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"发码";

    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-16],
        [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-32],
    ]];

    UILabel *hint = [self makeLabel:@"粘贴用户在中邮司机帮 SEC 面板复制的 UUID，生成激活码发给对方。"
                                font:[UIFont systemFontOfSize:12]
                               color:[UIColor secondaryLabelColor]];
    hint.numberOfLines = 0;
    [stack addArrangedSubview:hint];

    [stack addArrangedSubview:[self sectionTitle:@"目标设备 UUID"]];
    self.uuidField = [self textField:@"粘贴 UUID" mono:YES];
    [stack addArrangedSubview:self.uuidField];

    UIStackView *uuidBtns = [[UIStackView alloc] init];
    uuidBtns.axis = UILayoutConstraintAxisHorizontal;
    uuidBtns.spacing = 10;
    uuidBtns.distribution = UIStackViewDistributionFillEqually;
    [uuidBtns addArrangedSubview:[self actionButton:@"从剪贴板粘贴" action:@selector(pasteUUID)]];
    [uuidBtns addArrangedSubview:[self actionButton:@"清空" action:@selector(clearUUID)]];
    [stack addArrangedSubview:uuidBtns];

    self.shortLabel = [self makeLabel:@"短码：—"
                                 font:[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium]
                                color:[UIColor labelColor]];
    [stack addArrangedSubview:self.shortLabel];

    [stack addArrangedSubview:[self sectionTitle:@"有效天数"]];
    self.daysField = [self textField:@"365" mono:NO];
    self.daysField.keyboardType = UIKeyboardTypeNumberPad;
    self.daysField.text = @"365";
    [self.daysField addTarget:self action:@selector(refreshPreview) forControlEvents:UIControlEventEditingChanged];
    [stack addArrangedSubview:self.daysField];

    self.expiryPreviewLabel = [self makeLabel:@"预计到期：—"
                                         font:[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular]
                                        color:[UIColor labelColor]];
    [stack addArrangedSubview:self.expiryPreviewLabel];

    [stack addArrangedSubview:[self actionButton:@"生成激活码" action:@selector(generateCode)]];

    [stack addArrangedSubview:[self sectionTitle:@"激活码"]];
    self.codeLabel = [self makeLabel:@"—"
                                font:[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium]
                               color:[UIColor systemBlueColor]];
    self.codeLabel.numberOfLines = 0;
    self.codeLabel.lineBreakMode = NSLineBreakByCharWrapping;
    [stack addArrangedSubview:self.codeLabel];

    UIStackView *codeBtns = [[UIStackView alloc] init];
    codeBtns.axis = UILayoutConstraintAxisHorizontal;
    codeBtns.spacing = 10;
    codeBtns.distribution = UIStackViewDistributionFillEqually;
    [codeBtns addArrangedSubview:[self actionButton:@"复制激活码" action:@selector(copyCode)]];
    [codeBtns addArrangedSubview:[self actionButton:@"校验" action:@selector(verifyCode)]];
    [stack addArrangedSubview:codeBtns];

    [self refreshPreview];
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

- (UITextField *)textField:(NSString *)placeholder mono:(BOOL)mono {
    UITextField *tf = [[UITextField alloc] init];
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.placeholder = placeholder;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    if (mono) {
        tf.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    }
    return tf;
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

- (NSInteger)daysValue {
    NSInteger days = [self.daysField.text integerValue];
    return days > 0 ? days : 365;
}

- (void)refreshPreview {
    NSString *exp = SecLicenseExpiryFromDays([self daysValue]);
    self.expiryPreviewLabel.text = [NSString stringWithFormat:@"预计到期：%@", SecLicenseExpiryDisplay(exp)];

    NSString *uuid = SecLicenseNormalizeUUID(self.uuidField.text);
    if (uuid.length) {
        self.shortLabel.text = [NSString stringWithFormat:@"短码：%@", SecLicenseDeviceCodeShort(uuid) ?: @"—"];
    } else {
        self.shortLabel.text = @"短码：—";
    }
}

- (void)pasteUUID {
    NSString *clip = UIPasteboard.generalPasteboard.string;
    if (!clip.length) {
        [self alert:@"剪贴板为空"];
        return;
    }
    self.uuidField.text = clip;
    [self refreshPreview];
}

- (void)clearUUID {
    self.uuidField.text = @"";
    self.codeLabel.text = @"—";
    [self refreshPreview];
}

- (void)generateCode {
    NSString *uuid = SecLicenseNormalizeUUID(self.uuidField.text);
    if (!uuid.length) {
        [self alert:@"请输入有效的设备 UUID"];
        return;
    }
    NSString *expiry = SecLicenseExpiryFromDays([self daysValue]);
    NSString *code = SecLicenseGenerateCodeWithExpiry(uuid, kSecLicenseDefaultSecret, expiry);
    if (!code.length) {
        [self alert:@"生成失败"];
        return;
    }
    self.codeLabel.text = code;
    self.shortLabel.text = [NSString stringWithFormat:@"短码：%@", SecLicenseDeviceCodeShort(uuid) ?: @"—"];
    self.expiryPreviewLabel.text = [NSString stringWithFormat:@"预计到期：%@", SecLicenseExpiryDisplay(expiry)];
    [self flash:@"已生成"];
}

- (void)copyCode {
    NSString *code = self.codeLabel.text;
    if (!code.length || [code isEqualToString:@"—"]) {
        [self alert:@"请先生成激活码"];
        return;
    }
    UIPasteboard.generalPasteboard.string = code;
    [self flash:@"已复制激活码"];
}

- (void)verifyCode {
    NSString *uuid = SecLicenseNormalizeUUID(self.uuidField.text);
    NSString *code = self.codeLabel.text;
    if (!uuid.length || !code.length || [code isEqualToString:@"—"]) {
        [self alert:@"请先填写 UUID 并生成激活码"];
        return;
    }
    if (SecLicenseVerify(uuid, code, kSecLicenseDefaultSecret)) {
        NSString *exp = SecLicenseExpiryFromCode(code);
        [self alert:[NSString stringWithFormat:@"校验通过 ✓\n到期：%@", SecLicenseExpiryDisplay(exp)]];
    } else {
        [self alert:@"校验失败：UUID 不匹配、签名错误或已过期"];
    }
}

- (void)flash:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:nil message:msg preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:a animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
