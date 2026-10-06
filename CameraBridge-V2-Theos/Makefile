TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

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

CameraBridgeV2_CFLAGS := -fobjc-arc -Wno-deprecated-declarations
CameraBridgeV2_CCFLAGS := -std=c++17 -fobjc-arc
CameraBridgeV2_FRAMEWORKS := AVFoundation CoreMedia CoreVideo CoreImage VideoToolbox UIKit QuartzCore Foundation
CameraBridgeV2_LIBRARIES := c++ bz2 z
CameraBridgeV2_LDFLAGS := -Wl,-segalign,0x4000

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 TikTok 2>/dev/null || true"

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
  ARCHS := arm64 arm64e
endif
