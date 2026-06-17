# Build on macOS with Theos installed.
#   export THEOS=~/theos
#   make package
#
# Or install dylib only:
#   make

TARGET := iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = tplayer

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TPlayerFakeVIP

TPlayerFakeVIP_FILES = Tweak.x
TPlayerFakeVIP_CFLAGS = -fobjc-arc -Wno-unused-function
TPlayerFakeVIP_FRAMEWORKS = Foundation UIKit

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 tplayer 2>/dev/null || true"
