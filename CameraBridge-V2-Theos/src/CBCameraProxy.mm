#import "CBCameraProxy.h"
#import "CBStreamManager.h"
#import "CBSettings.h"
#import "CBSampleBufferFactory.h"

@interface CBCameraProxy ()
@property(nonatomic, strong) id original;
@property(nonatomic) dispatch_queue_t originalQueue;

// 1 s throttled diagnostic counters
@property(nonatomic) NSUInteger camFramesWindow;
@property(nonatomic) NSUInteger replFetchedWindow;
@property(nonatomic) NSUInteger sbufCreatedWindow;
@property(nonatomic) NSUInteger replDeliveredWindow;
@property(nonatomic) NSUInteger origFramesWindow;
@property(nonatomic) NSDate *logWindowStart;
@end

@implementation CBCameraProxy

- (instancetype)initWithOriginal:(id)original queue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _original = original;
        _originalQueue = queue;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    CMSampleBufferRef send = sampleBuffer;
    CVPixelBufferRef camera = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferRef repl = NULL;
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);

    if ([CBSettings shared].enabled && camera) {
        repl = [[CBStreamManager shared] copyLatestFrameForTarget:camera pts:&pts];
        if (repl) {
            _replFetchedWindow++;
            CMSampleBufferRef s = CBCreateSampleBufferLike(sampleBuffer, repl);
            if (s) {
                _sbufCreatedWindow++;
                send = s;
            }
            // fallback: keep original sample buffer
        }
    }

    id target = _original;
    if (target && [target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [target captureOutput:output didOutputSampleBuffer:send fromConnection:connection];
    }
    if (send != sampleBuffer) {
        _replDeliveredWindow++;
        [CBStreamManager updateSourceState:@"INJECTING"];
        CFRelease(send);
    } else {
        _origFramesWindow++;
    }
    if (repl) CVPixelBufferRelease(repl);
    [self logStatsIfDue:camera];
}

- (void)logStatsIfDue:(CVPixelBufferRef)camera {
    _camFramesWindow++;
    NSDate *now = [NSDate date];
    if (!_logWindowStart) { _logWindowStart = now; return; }
    NSTimeInterval dt = [now timeIntervalSinceDate:_logWindowStart];
    if (dt < 1.0) return;
    _logWindowStart = now;
    CGFloat fps = (CGFloat)_camFramesWindow / MAX(dt, 0.001);
    size_t w = camera ? CVPixelBufferGetWidth(camera) : 0;
    size_t h = camera ? CVPixelBufferGetHeight(camera) : 0;
    OSType fmt = camera ? CVPixelBufferGetPixelFormatType(camera) : 0;
    NSLog(@"[CBV2] camera frame received fps=%.1f %zux%zu fmt=%c%c%c%c",
          fps, w, h,
          (char)((fmt >> 24) & 0xFF), (char)((fmt >> 16) & 0xFF),
          (char)((fmt >> 8) & 0xFF), (char)(fmt & 0xFF));
    if (_replDeliveredWindow > 0) {
        NSLog(@"[CBV2] replacement frame fetched=%lu sampleBuffer created=%lu delivered=%lu",
              (unsigned long)_replFetchedWindow, (unsigned long)_sbufCreatedWindow,
              (unsigned long)_replDeliveredWindow);
    } else if (_origFramesWindow > 0) {
        NSLog(@"[CBV2] original camera frame (no replacement) frames=%lu",
              (unsigned long)_origFramesWindow);
    }
    _camFramesWindow = 0;
    _replFetchedWindow = 0;
    _sbufCreatedWindow = 0;
    _replDeliveredWindow = 0;
    _origFramesWindow = 0;
}

- (void)captureOutput:(AVCaptureOutput *)output
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    id target = _original;
    if (target && [target respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [target captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:) ||
        aSelector == @selector(captureOutput:didDropSampleBuffer:fromConnection:)) {
        return YES;
    }
    return [_original respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    return [_original conformsToProtocol:protocol] || [super conformsToProtocol:protocol];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [_original methodSignatureForSelector:sel] ?: [super methodSignatureForSelector:sel];
}

- (void)forwardInvocation:(NSInvocation *)inv {
    if ([_original respondsToSelector:inv.selector]) {
        [inv invokeWithTarget:_original];
    }
}

@end
