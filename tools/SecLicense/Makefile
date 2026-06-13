TARGET := iphone:clang:16.5:13.0
INSTALL_TARGET_PROCESSES = SecLicense

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = SecLicense
SecLicense_FILES = SecLicenseApp/main.m SecLicenseApp/AppDelegate.m SecLicenseApp/IssueViewController.m SecLicenseApp/ViewController.m SecLicenseApp/SecDeviceID.m SecLicenseApp/SecLicenseCore.m
SecLicense_FRAMEWORKS = UIKit Foundation Security
SecLicense_CFLAGS = -fobjc-arc
SecLicense_INSTALL_PATH = /Applications

include $(THEOS)/makefiles/application.mk

.PHONY: ipa
ipa: clean package
	@echo "IPA: $(THEOS_STAGING)/../packages/*.deb (Theos) — 或使用 build_ipa.sh 生成 TrollStore IPA"
