ARCHS = arm64
TARGET = iphone:clang:latest:13.0
INSTALL_TARGET_PROCESSES = XiangPostDriver

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = SecToggle

SecToggle_FILES = SecToggle.m
SecToggle_CFLAGS = -fobjc-arc
SecToggle_FRAMEWORKS = UIKit Foundation CoreLocation

include $(THEOS_MAKE_PATH)/library.mk
