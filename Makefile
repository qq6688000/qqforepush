TARGET := iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = QQ

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = QQForePush

QQForePush_FILES = Tweak.x
QQForePush_FRAMEWORKS = UserNotifications AudioToolbox
QQForePush_CFLAGS = -fobjc-arc -Wno-unguarded-availability-new -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
