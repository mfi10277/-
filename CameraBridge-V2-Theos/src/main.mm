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
        CBCameraProxy *proxy=[[CBCameraProxy alloc] initWithOriginal:delegate queue:queue];
        objc_setAssociatedObject(self,kCBProxyKey,proxy,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, queue);
        NSLog(@"[CBV2] camera delegate hooked: %@", delegate);
        return;
    }
    %orig;
}
%end

%ctor {
    @autoreleasepool {
        [[CBSettings shared] load];
        NSLog(@"[CBV2] injected");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if ([CBSettings shared].streamURL.length == 0) {
                [[CBControlPanel shared] show];
            }
        });
    }
}
