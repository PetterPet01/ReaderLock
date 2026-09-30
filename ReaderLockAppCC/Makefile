ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

BUNDLE_NAME = ReaderLockAppCC
ReaderLockAppCC_FILES = ReaderLockAppCC.m
ReaderLockAppCC_CFLAGS = -fobjc-arc -I../Common
ReaderLockAppCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ReaderLockAppCC_BUNDLE_EXTENSION = bundle
ReaderLockAppCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ReaderLockAppCC_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
