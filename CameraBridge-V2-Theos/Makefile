# CameraBridge V2 — Theos rootless tweak
# Target: iPhone 11 / iOS 15.3.1 / TrollStore / TrollFools
#
# waruhachi/sdks provides iPhoneOS15.6.sdk (no 15.0), so we build against 15.6
# while keeping the deployment target at iOS 15.0 for 15.3.1 devices.

TARGET := iphone:clang:latest:15.6
IPHONEOS_DEPLOYMENT_TARGET := 15.0
ARCHS := arm64 arm64e

# Rootless is the default packaging scheme for TrollStore / TrollFools targets.
THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := CameraBridgeV2

CameraBridgeV2_FILES := src/main.mm \
    src/CBSettings.mm \
    src/CBStreamManager.mm \
    src/CBHTTPFLVSource.mm \
    src/CBHLSSource.mm \
    src/CBH264Decoder.mm \
    src/CBFrameQueue.mm \
    src/CBCameraProxy.mm \
    src/CBSampleBufferFactory.mm \
    src/CBControlPanel.mm

CameraBridgeV2_CFLAGS := -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
CameraBridgeV2_OBJCFLAGS := -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
CameraBridgeV2_OBJCCFLAGS := -std=c++17 -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
CameraBridgeV2_CCFLAGS := -std=c++17 -fobjc-arc

CameraBridgeV2_FRAMEWORKS := AVFoundation CoreMedia CoreVideo CoreImage VideoToolbox UIKit QuartzCore Foundation
CameraBridgeV2_LIBRARIES := c++ bz2 z
CameraBridgeV2_LDFLAGS := -Wl,-segalign,0x4000

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 TikTok 2>/dev/null || true"
