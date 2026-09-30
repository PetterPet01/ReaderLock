ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = SpringBoard Books

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ReaderLockSB ReaderLockBooks

ReaderLockSB_FILES = SpringBoard.xm
ReaderLockSB_CFLAGS = -fobjc-arc -ICommon
ReaderLockSB_FRAMEWORKS = Foundation UIKit CoreFoundation QuartzCore LocalAuthentication

ReaderLockBooks_FILES = Books.xm
ReaderLockBooks_CFLAGS = -fobjc-arc -ICommon
ReaderLockBooks_FRAMEWORKS = Foundation UIKit QuartzCore LocalAuthentication

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += ReaderLockMonoCC ReaderLockColorCC
include $(THEOS_MAKE_PATH)/aggregate.mk
