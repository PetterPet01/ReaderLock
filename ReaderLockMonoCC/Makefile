ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

BUNDLE_NAME = ReaderLockMonoCC
ReaderLockMonoCC_FILES = ReaderLockMonoCC.m
ReaderLockMonoCC_CFLAGS = -fobjc-arc -I../Common
ReaderLockMonoCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ReaderLockMonoCC_BUNDLE_EXTENSION = bundle
ReaderLockMonoCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ReaderLockMonoCC_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
