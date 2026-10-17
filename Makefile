export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = SpringBoard
DEBUG = 0
FINALPACKAGE = 1
# rootless 越狱用 rootless；roothide 越狱改成 roothide
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = systemPro
systemPro_FILES = Tweak.x Prefs.m \
	Features/StatusBar.x Features/Disable.x \
	Features/VPN.x Features/RunIndicator.x
systemPro_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
systemPro_FRAMEWORKS = UIKit Foundation QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "sbreload || killall -9 SpringBoard"
