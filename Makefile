TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e
INSTALL_TARGET_PROCESSES := SpringBoard

# 无根越狱（/var/jb）用 rootless；有根越狱把这一行删掉
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := BarkAutoCopy
BarkAutoCopy_FILES := BarkAutoCopy.m
BarkAutoCopy_CFLAGS := -fobjc-arc
BarkAutoCopy_FRAMEWORKS := UIKit UserNotifications Foundation
BarkAutoCopy_LIBRARIES := substrate

include $(THEOS_MAKE_PATH)/tweak.mk
