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
@property(nonatomic) NSDate *pixelLogStart;
@end

@implementation CBStreamManager {
    os_unfair_lock _cacheLock;
}

// --- CBV2.SourceState (thread-safe diagnostic state) -------------------------
static NSString *CBV2SourceState = @"NO_URL";
static os_unfair_lock s_stateLock = OS_UNFAIR_LOCK_INIT;

+ (void)updateSourceState:(NSString *)state {
    if (!state.length) return;
    os_unfair_lock_lock(&s_stateLock);
    CBV2SourceState = [state copy];
    os_unfair_lock_unlock(&s_stateLock);
}

+ (NSString *)sourceState {
    os_unfair_lock_lock(&s_stateLock);
    NSString *r = [CBV2SourceState copy];
    os_unfair_lock_unlock(&s_stateLock);
    return r;
}
// ----------------------------------------------------------------------------

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
    if (!s.enabled) { [CBStreamManager updateSourceState:@"NO_URL"]; return; }
    NSString *u = s.streamURL;
    if (!u.length) { [CBStreamManager updateSourceState:@"NO_URL"]; return; }
    NSURL *url = [NSURL URLWithString:u];
    if (!url) { [CBStreamManager updateSourceState:@"NO_URL"]; return; }
    if (![url.scheme isEqualToString:@"http"] && ![url.scheme isEqualToString:@"https"]) {
        [CBStreamManager updateSourceState:@"NO_URL"];
        return;
    }
    if (!url.host.length) { [CBStreamManager updateSourceState:@"NO_URL"]; return; }

    [CBStreamManager updateSourceState:@"CONNECTING"];

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

- (BOOL)isStarted {
    __block BOOL started = NO;
    dispatch_sync(_lifecycleLock, ^{ started = _started; });
    return started;
}

- (void)restart {
    [self stop];
    NSLog(@"[CBV2] stream restart");
    [self startIfNeeded];
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
    OSType tgtFmt = CVPixelBufferGetPixelFormatType(target);
    OSType srcFmt = CVPixelBufferGetPixelFormatType(src);
    [self logPixelFormatsIfDue:srcFmt target:tgtFmt];   // e.g. [CBV2] source=420v target=420f

    CIImage *image = [self imageForBuffer:src targetSize:CGSizeMake(w, h)];
    CVPixelBufferRelease(src);
    if (!image) return NULL;

    CVPixelBufferRef out = NULL;
    if ([self isDirectCIPixelFormat:tgtFmt]) {
        // Primary path: Core Image renders directly into the target format
        // (32BGRA / 420v / 420f / bi-planar video-range). CI render:toCVPixelBuffer:
        // has no OSStatus to check, so the whitelist above is the success gate and
        // any format outside it falls through to the fallback below.
        out = [self createBuffer:w h:h fmt:tgtFmt];
        if (out) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            [self.ci render:image toCVPixelBuffer:out bounds:CGRectMake(0, 0, w, h) colorSpace:cs];
            CGColorSpaceRelease(cs);
        }
    }
    if (!out) {
        // Compatibility path (iOS 15: VTPixelTransferSession is iOS 16+, so CI
        // renders to the most common camera format 420f instead of failing on an
        // exotic target format).
        NSLog(@"[CBV2] pixel path: CI fallback to 420f (target=%s unsupported)",
              [self fourCC:tgtFmt].UTF8String);
        out = [self createBuffer:w h:h fmt:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange];
        if (out) {
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            [self.ci render:image toCVPixelBuffer:out bounds:CGRectMake(0, 0, w, h) colorSpace:cs];
            CGColorSpaceRelease(cs);
        }
    }
    if (!out) return NULL;

    [self replaceCached:out pts:srcPTS];
    _fpsInjected++;
    [CBStreamManager updateSourceState:@"FRAME_READY"];
    if (pts) *pts = srcPTS;
    [self logFPSIfDue];
    return out;
}

#pragma mark - Pixel format helpers

- (NSString *)fourCC:(OSType)fmt {
    char c[5] = {
        (char)((fmt >> 24) & 0xFF), (char)((fmt >> 16) & 0xFF),
        (char)((fmt >> 8) & 0xFF), (char)(fmt & 0xFF), 0
    };
    return [NSString stringWithCString:c encoding:NSISOLatin1String] ?: @"????";
}

- (BOOL)isDirectCIPixelFormat:(OSType)fmt {
    switch (fmt) {
        case kCVPixelFormatType_32BGRA:
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:  // 420v
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:   // 420f
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_4444YpCbCrA8:
            return YES;
        default:
            return NO;
    }
}

- (CVPixelBufferRef)createBuffer:(size_t)w h:(size_t)h fmt:(OSType)fmt {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
    };
    CVPixelBufferRef out = NULL;
    OSStatus st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, fmt,
                                      (__bridge CFDictionaryRef)attrs, &out);
    if (st != kCVReturnSuccess) {
        NSLog(@"[CBV2] error: CVPixelBufferCreate failed status=%d", (int)st);
        return NULL;
    }
    return out;
}

- (void)logPixelFormatsIfDue:(OSType)src target:(OSType)tgt {
    NSDate *now = [NSDate date];
    if (!_pixelLogStart) { _pixelLogStart = now; return; }
    if ([now timeIntervalSinceDate:_pixelLogStart] < 1.0) return;
    _pixelLogStart = now;
    NSLog(@"[CBV2] pixel source=%s target=%s",
          [self fourCC:src].UTF8String, [self fourCC:tgt].UTF8String);
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
