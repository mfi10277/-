#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "CBCameraProxy.h"
#import "CBControlPanel.h"
#import "CBSettings.h"

static const void *kCBProxyKey = &kCBProxyKey;

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (delegate && ![delegate isKindOfClass:[CBCameraProxy class]]) {
        CBCameraProxy *proxy = [[CBCameraProxy alloc] initWithOriginal:delegate queue:queue];
        objc_setAssociatedObject(self, kCBProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, queue);
        NSLog(@"[CBV2] camera delegate hooked: %@", delegate);
        return;
    }
    %orig;
}

- (instancetype)init {
    NSLog(@"[CBV2] AVCaptureVideoDataOutput created");
    self = %orig;
    return self;
}

- (instancetype)initWithVideoSettings:(NSDictionary *)settings {
    NSLog(@"[CBV2] AVCaptureVideoDataOutput created with settings: %@", settings);
    self = %orig;
    return self;
}

%end

// Diagnostics only (public API): helps confirm whether the target app routes video
// through AVCaptureVideoDataOutput before considering any compatibility layer.
%hook AVCaptureSession

- (void)startRunning {
    NSLog(@"[CBV2] AVCaptureSession startRunning (%lu outputs)", (unsigned long)self.outputs.count);
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        CBSettings *settings = [CBSettings shared]; // load + [CBV2] settings loaded
        NSLog(@"[CBV2] injected");
        NSLog(@"[CBV2] configured: enabled=%d autostart=%d mirror=%d rotation=%ld aspect=%ld url=%@",
              settings.enabled,
              settings.autoStart,
              settings.mirror,
              (long)settings.rotation,
              (long)settings.aspectMode,
              settings.streamURL);
        // AutoStart: AutoStart && Enabled && URL present -> start the network stream.
        if (settings.autoStart && settings.enabled && settings.streamURL.length > 0) {
            NSLog(@"[CBV2] autostart = YES");
            [[CBStreamManager shared] startIfNeeded];
        } else {
            NSLog(@"[CBV2] autostart = NO");
        }
        // Show the control panel on every launch, independent of StreamURL/Enabled/AutoStart.
        // CBControlPanel guards against duplicate presentation.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[CBControlPanel shared] show];
        });
    }
}
