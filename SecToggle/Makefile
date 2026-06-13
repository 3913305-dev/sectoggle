ARCHS = arm64
TARGET = iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = XiangPostDriver

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = SecToggle

SecToggle_FILES = SecToggle.m SecLicenseCore.m SecDeviceID.m
SecToggle_CFLAGS = -fobjc-arc
SecToggle_FRAMEWORKS = UIKit Foundation CoreLocation Security

include $(THEOS_MAKE_PATH)/library.mk
