ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

BUNDLE_NAME = ReaderLockColorCC
ReaderLockColorCC_FILES = ReaderLockColorCC.m
ReaderLockColorCC_CFLAGS = -fobjc-arc -I../Common
ReaderLockColorCC_INSTALL_PATH = /Library/ControlCenter/Bundles/
ReaderLockColorCC_BUNDLE_EXTENSION = bundle
ReaderLockColorCC_PRIVATE_FRAMEWORKS = ControlCenterUIKit
ReaderLockColorCC_FRAMEWORKS = UIKit Foundation

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
