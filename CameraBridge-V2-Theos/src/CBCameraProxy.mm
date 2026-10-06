#import "CBCameraProxy.h"
#import "CBStreamManager.h"
#import "CBSettings.h"
#import "CBSampleBufferFactory.h"

@interface CBCameraProxy ()
@property(nonatomic, weak) id original;
@property(nonatomic) dispatch_queue_t originalQueue;
@end

@implementation CBCameraProxy
- (instancetype)initWithOriginal:(id)original queue:(dispatch_queue_t)queue {
    if ((self=[super init])) { _original=original; _originalQueue=queue; }
    return self;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CMSampleBufferRef send=sampleBuffer;
    CVPixelBufferRef camera=CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferRef repl=NULL;
    CMTime pts=CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if ([CBSettings shared].enabled && camera) {
        repl=[[CBStreamManager shared] copyLatestFrameForTarget:camera pts:&pts];
        if (repl) {
            CMSampleBufferRef s=CBCreateSampleBufferLike(sampleBuffer,repl);
            if (s) send=s;
            else send=sampleBuffer;
        }
    }
    id target=_original;
    if (target && [target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [target captureOutput:output didOutputSampleBuffer:send fromConnection:connection];
    }
    if (send != sampleBuffer) CFRelease(send);
    if (repl) CVPixelBufferRelease(repl);
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    id target=_original;
    if (target && [target respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)])
        [target captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    if (aSelector==@selector(captureOutput:didOutputSampleBuffer:fromConnection:) ||
        aSelector==@selector(captureOutput:didDropSampleBuffer:fromConnection:)) return YES;
    return [_original respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    return [_original methodSignatureForSelector:sel] ?: [super methodSignatureForSelector:sel];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    if ([_original respondsToSelector:inv.selector]) [inv invokeWithTarget:_original];
}
@end
