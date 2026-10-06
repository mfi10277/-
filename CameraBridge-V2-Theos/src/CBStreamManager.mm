#import "CBStreamManager.h"
#import "CBSettings.h"
#import "CBFrameQueue.h"
#import "CBHLSSource.h"
#import "CBHTTPFLVSource.h"
#import <CoreImage/CoreImage.h>
#import <os/lock.h>

@interface CBStreamManager ()
@property(nonatomic) CBFrameQueue *queue;
@property(nonatomic) id source;
@property(nonatomic) BOOL started;
@property(nonatomic) CIContext *ci;
@property(nonatomic) dispatch_queue_t lifecycleLock;

// Rendered-frame cache (avoids re-rendering the same network frame per camera callback)
@property(nonatomic) CVPixelBufferRef cachedOut;
@property(nonatomic) CMTime cachedPTS;
@property(nonatomic) BOOL cachedValid;

// FPS stats (1 s window)
@property(nonatomic) NSDate *fpsWindowStart;
@property(nonatomic) NSUInteger fpsDecoded;
@property(nonatomic) NSUInteger fpsInjected;
@end

@implementation CBStreamManager {
    os_unfair_lock _cacheLock;
}

+ (instancetype)shared {
    static CBStreamManager *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [CBStreamManager new];
        s.queue = [[CBFrameQueue alloc] initWithMaxCount:3];
        s.ci = [CIContext context];
        s.lifecycleLock = dispatch_queue_create("com.camerabridge.lifecycle", DISPATCH_QUEUE_SERIAL);
        s.fpsWindowStart = [NSDate date];
        s.cachedPTS = kCMTimeInvalid;
        s->_cacheLock = OS_UNFAIR_LOCK_INIT;
    });
    return s;
}

- (void)dealloc {
    [self stop];
    if (_cachedOut) CVPixelBufferRelease(_cachedOut);
}

#pragma mark - Lifecycle

- (void)startIfNeeded {
    __block BOOL shouldStart = NO;
    dispatch_sync(_lifecycleLock, ^{ shouldStart = !_started; });
    if (!shouldStart) return;

    CBSettings *s = [CBSettings shared];
    if (!s.enabled) return;
    NSString *u = s.streamURL;
    if (!u.length) return;
    NSURL *url = [NSURL URLWithString:u];
    if (!url) return;
    if (![url.scheme isEqualToString:@"http"] && ![url.scheme isEqualToString:@"https"]) return;
    if (!url.host.length) return;

    __weak __typeof__(self) weakSelf = self;
    void (^block)(CVPixelBufferRef, CMTime) = ^(CVPixelBufferRef b, CMTime pts) {
        __strong __typeof__(weakSelf) self = weakSelf;
        if (!self) return;
        [self.queue push:b pts:pts];
        self.fpsDecoded++;
    };

    dispatch_sync(_lifecycleLock, ^{
        if (_started) return;
        _started = YES;
        NSString *path = url.path.lowercaseString ?: @"";
        BOOL isHLS = [path hasSuffix:@".m3u8"];
        if (isHLS) {
            _source = [[CBHLSSource alloc] initWithURL:url frameBlock:block];
            NSLog(@"[CBV2] stream starting (HLS)");
        } else {
            _source = [[CBHTTPFLVSource alloc] initWithURL:url frameBlock:block];
            NSLog(@"[CBV2] stream starting (HTTP-FLV)");
        }
        [_source start];
    });
    NSLog(@"[CBV2] stream starting: %@", u);
}

- (void)stop {
    dispatch_sync(_lifecycleLock, ^{
        if (_source) {
            [_source stop];
            _source = nil;
        }
        _started = NO;
    });
    [_queue clear];
    [self invalidateCached];
    NSLog(@"[CBV2] stream stopped");
}

#pragma mark - Frame path

- (CVPixelBufferRef)copyLatestFrameForTarget:(CVPixelBufferRef)target pts:(CMTime *)pts {
    [self startIfNeeded];
    if (!target) return NULL;

    CMTime srcPTS = kCMTimeInvalid;
    CVPixelBufferRef src = [_queue copyLatestForTargetSize:CGSizeMake(CVPixelBufferGetWidth(target),
                                                                      CVPixelBufferGetHeight(target))
                                                       pts:&srcPTS];
    if (!src) return NULL;

    // Reuse the last rendered frame when no newer network frame arrived.
    os_unfair_lock_lock(&_cacheLock);
    if (_cachedValid && CMTIME_IS_NUMERIC(srcPTS) && CMTimeCompare(srcPTS, _cachedPTS) == 0) {
        CVPixelBufferRef out = (CVPixelBufferRef)CFRetain(_cachedOut);
        os_unfair_lock_unlock(&_cacheLock);
        if (pts) *pts = srcPTS;
        CVPixelBufferRelease(src);
        return out;
    }
    os_unfair_lock_unlock(&_cacheLock);

    size_t w = CVPixelBufferGetWidth(target);
    size_t h = CVPixelBufferGetHeight(target);
    OSType fmt = CVPixelBufferGetPixelFormatType(target);

    CVPixelBufferRef out = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt, (__bridge CFDictionaryRef)attrs, &out) != kCVReturnSuccess) {
        CVPixelBufferRelease(src);
        return NULL;
    }

    CIImage *image = [self imageForBuffer:src targetSize:CGSizeMake(w, h)];
    if (!image) {
        CVPixelBufferRelease(out);
        CVPixelBufferRelease(src);
        return NULL;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    [self.ci render:image toCVPixelBuffer:out bounds:CGRectMake(0, 0, w, h) colorSpace:cs];
    CGColorSpaceRelease(cs);
    CVPixelBufferRelease(src);

    [self replaceCached:out pts:srcPTS];
    _fpsInjected++;
    if (pts) *pts = srcPTS;
    [self logFPSIfDue];
    return out;
}

- (void)replaceCached:(CVPixelBufferRef)buf pts:(CMTime)pts {
    os_unfair_lock_lock(&_cacheLock);
    if (_cachedOut) CVPixelBufferRelease(_cachedOut);
    _cachedOut = (CVPixelBufferRef)CFRetain(buf);
    _cachedPTS = pts;
    _cachedValid = YES;
    os_unfair_lock_unlock(&_cacheLock);
}

- (void)invalidateCached {
    os_unfair_lock_lock(&_cacheLock);
    if (_cachedOut) {
        CVPixelBufferRelease(_cachedOut);
        _cachedOut = NULL;
    }
    _cachedValid = NO;
    _cachedPTS = kCMTimeInvalid;
    os_unfair_lock_unlock(&_cacheLock);
}

- (void)logFPSIfDue {
    NSDate *now = [NSDate date];
    if ([now timeIntervalSinceDate:_fpsWindowStart] < 1.0) return;
    NSTimeInterval dt = [now timeIntervalSinceDate:_fpsWindowStart];
    CGFloat fps = (CGFloat)_fpsInjected / MAX(dt, 0.001);
    NSLog(@"[CBV2] source=%@ fps=%.1f decoded=%lu injected=%lu",
          (_source && [_source isKindOfClass:[CBHLSSource class]]) ? @"hls" : @"flv",
          fps, (unsigned long)_fpsDecoded, (unsigned long)_fpsInjected);
    _fpsWindowStart = now;
    _fpsDecoded = 0;
    _fpsInjected = 0;
}

#pragma mark - Image adaptation (Fill/Fit/Stretch + Mirror + Rotation)

- (CIImage *)imageForBuffer:(CVPixelBufferRef)src targetSize:(CGSize)target {
    CIImage *image = [CIImage imageWithCVPixelBuffer:src];
    CGRect srcRect = image.extent;
    CGFloat sw = CGRectGetWidth(srcRect), sh = CGRectGetHeight(srcRect);
    if (sw <= 0 || sh <= 0) return nil;
    CGFloat tw = target.width, th = target.height;

    CBSettings *s = [CBSettings shared];

    NSInteger rotation = ((s.rotation % 360) + 360) % 360;
    if (rotation == 90) {
        image = [[image imageByApplyingTransform:CGAffineTransformMakeTranslation(0, sw)]
                 imageByApplyingTransform:CGAffineTransformMakeRotation(M_PI_2)];
        CGFloat tmp = sw; sw = sh; sh = tmp;
    } else if (rotation == 180) {
        image = [[image imageByApplyingTransform:CGAffineTransformMakeTranslation(sw, sh)]
                 imageByApplyingTransform:CGAffineTransformMakeRotation(M_PI)];
    } else if (rotation == 270) {
        image = [[image imageByApplyingTransform:CGAffineTransformMakeTranslation(sh, 0)]
                 imageByApplyingTransform:CGAffineTransformMakeRotation(-M_PI_2)];
        CGFloat tmp = sw; sw = sh; sh = tmp;
    }

    if (s.mirror) {
        CGRect e = image.extent;
        image = [[image imageByApplyingTransform:CGAffineTransformMakeTranslation(CGRectGetWidth(e), 0)]
                 imageByApplyingTransform:CGAffineTransformMakeScale(-1, 1)];
    }

    NSInteger mode = s.aspectMode; // 0=Fill 1=Fit 2=Stretch
    CGFloat sx = tw / sw, sy = th / sh;

    if (mode == 2) { // Stretch
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(sx, sy)];
        return [image imageByCroppingToRect:CGRectMake(0, 0, tw, th)];
    }

    CGFloat scale = (mode == 1) ? MIN(sx, sy) : MAX(sx, sy); // 1=Fit, 0=Fill
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect e = image.extent;
    CGFloat dx = (tw - CGRectGetWidth(e)) * 0.5 - CGRectGetMinX(e);
    CGFloat dy = (th - CGRectGetHeight(e)) * 0.5 - CGRectGetMinY(e);
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(dx, dy)];
    if (mode == 0) {
        image = [image imageByCroppingToRect:CGRectMake(0, 0, tw, th)];
    }
    // Composite over black so letterbox/pillarbox areas are black, not garbage.
    return [image imageByCompositingOverImage:[CIImage imageWithColor:[CIColor blackColor]]];
}

@end
