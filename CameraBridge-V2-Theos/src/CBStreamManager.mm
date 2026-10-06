#import "CBStreamManager.h"
#import "CBSettings.h"
#import "CBFrameQueue.h"
#import "CBHLSSource.h"
#import "CBHTTPFLVSource.h"
#import "CBSampleBufferFactory.h"
#import <CoreImage/CoreImage.h>

@interface CBStreamManager ()
@property(nonatomic) CBFrameQueue *queue;
@property(nonatomic) id source;
@property(nonatomic) BOOL started;
@property(nonatomic) CIContext *ci;
@end

@implementation CBStreamManager
+ (instancetype)shared {
    static CBStreamManager *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s=[CBStreamManager new]; s.queue=[CBFrameQueue new]; s.ci=[CIContext context]; });
    return s;
}
- (void)startIfNeeded {
    if (_started) return;
    NSString *u=[CBSettings shared].streamURL;
    if (!u.length) return;
    NSURL *url=[NSURL URLWithString:u];
    if (!url) return;
    _started=YES;
    __weak typeof(self) weakSelf=self;
    void (^block)(CVPixelBufferRef,CMTime)=^(CVPixelBufferRef b, CMTime pts){
        __strong typeof(weakSelf) self=weakSelf; if (!self) return;
        [self.queue push:b pts:pts];
    };
    if ([[url.pathExtension lowercaseString] isEqualToString:@"m3u8"]) {
        _source=[[CBHLSSource alloc] initWithURL:url frameBlock:block];
    } else {
        _source=[[CBHTTPFLVSource alloc] initWithURL:url frameBlock:block];
    }
    [_source start];
    NSLog(@"[CBV2] stream started: %@", u);
}
- (void)stop {
    [_source stop]; _source=nil; [_queue clear]; _started=NO;
}
- (CVPixelBufferRef)copyLatestFrameForTarget:(CVPixelBufferRef)target pts:(CMTime *)pts {
    if (!_started) [self startIfNeeded];
    CVPixelBufferRef src=[_queue copyLatestForTargetSize:CGSizeMake(CVPixelBufferGetWidth(target),CVPixelBufferGetHeight(target)) pts:pts];
    if (!src) return NULL;

    size_t w=CVPixelBufferGetWidth(target), h=CVPixelBufferGetHeight(target);
    OSType fmt=CVPixelBufferGetPixelFormatType(target);
    CVPixelBufferRef out=NULL;
    NSDictionary *attrs=@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault,w,h,fmt,(__bridge CFDictionaryRef)attrs,&out)!=kCVReturnSuccess) {
        CVPixelBufferRelease(src); return NULL;
    }
    CIImage *image=[CIImage imageWithCVPixelBuffer:src];
    CIImage *scaled=[image imageByCroppingToRect:CGRectMake(0,0,w,h)];
    if ([CBSettings shared].mirror) scaled=[scaled imageByApplyingTransform:CGAffineTransformMakeScale(-1,1)];
    [self.ci render:scaled toCVPixelBuffer:out bounds:CGRectMake(0,0,w,h) colorSpace:CGColorSpaceCreateDeviceRGB()];
    CVPixelBufferRelease(src);
    return out;
}
@end
