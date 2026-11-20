THEOS ?= /opt/theos
TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME ?= rootless
INSTALL_TARGET_PROCESSES = YouTube SpringBoard
FINALPACKAGE = 1

include $(THEOS)/makefiles/common.mk

# Package architecture follows the scheme: rootless (iphoneos-arm64), roothide (iphoneos-arm64e, needs
# roothide's Theos) or rootful (iphoneos-arm). Build rootful with: make package THEOS_PACKAGE_SCHEME=
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
THEOS_PACKAGE_ARCH = iphoneos-arm64
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
THEOS_PACKAGE_ARCH = iphoneos-arm64e
else
THEOS_PACKAGE_ARCH = iphoneos-arm
endif

# YTHideProgress: the YouTube part. Also the dylib to inject into a sideloaded YouTube app.
# YTHideProgressSB: the SpringBoard part (picture in picture), jailbreak only.
TWEAK_NAME = YTHideProgress YTHideProgressSB

YTHideProgress_FILES = Tweak.x
YTHideProgress_CFLAGS = -fobjc-arc
YTHideProgress_FRAMEWORKS = UIKit

YTHideProgressSB_FILES = SpringBoard.x
YTHideProgressSB_CFLAGS = -fobjc-arc -Wno-arc-performSelector-leaks
YTHideProgressSB_FRAMEWORKS = UIKit
YTHideProgressSB_PRIVATE_FRAMEWORKS = MobileCoreServices

include $(THEOS_MAKE_PATH)/tweak.mk
