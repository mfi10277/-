#import "CBH264Decoder.h"
#import <VideoToolbox/VideoToolbox.h>

@interface CBH264Decoder ()
@property(nonatomic) CMVideoFormatDescriptionRef format;
@property(nonatomic) VTDecompressionSessionRef session;
@property(nonatomic) CVPixelBufferRef latest;
@property(nonatomic) CMTime latestPTS;
@property(nonatomic) NSData *sps;
@property(nonatomic) NSData *pps;
@property(nonatomic) uint32_t pendingCount;   // frames submitted, not yet decoded
@property(nonatomic) uint32_t decodedCount;
@property(nonatomic) uint32_t droppedCount;
@property(nonatomic) NSDate *fpsWindowStart;
@property(nonatomic) NSUInteger fpsWindowCount;
@end

@implementation CBH264Decoder

- (instancetype)init {
    if ((self = [super init])) {
        _nalLengthSize = 4;
        _latestPTS = kCMTimeInvalid;
    }
    return self;
}

- (void)dealloc {
    [self reset];
}

#pragma mark - VT callback

static void CBDecodeCallback(void *decompressionOutputRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTimeStamp,
                             CMTime presentationDuration) {
    CBH264Decoder *self = (__bridge CBH264Decoder *)decompressionOutputRefCon;
    BOOL success = (status == noErr && imageBuffer != NULL);
    @synchronized (self) {
        if (success && self.latest) CVPixelBufferRelease(self.latest);
        if (success) self.latest = (CVPixelBufferRef)CFRetain(imageBuffer);
        if (success) self.latestPTS = presentationTimeStamp;
        if (self.pendingCount > 0) self.pendingCount--;
        if (success) self.decodedCount++;
        if (success) [self logDecodedFPSIfDue];
    }
    if (!success) return;
    if (self.onFrameDecoded) {
        self.onFrameDecoded((CVPixelBufferRef)imageBuffer, presentationTimeStamp);
    }
}

#pragma mark - Decode FPS (1 s cadence, not per frame)

- (void)logDecodedFPSIfDue {
    NSDate *now = [NSDate date];
    if (!_fpsWindowStart) { _fpsWindowStart = now; _fpsWindowCount = 0; return; }
    NSTimeInterval dt = [now timeIntervalSinceDate:_fpsWindowStart];
    if (dt < 1.0) return;
    CGFloat fps = (CGFloat)_fpsWindowCount / MAX(dt, 0.001);
    NSLog(@"[CBV2] decoded fps=%.1f", fps);
    _fpsWindowStart = now;
    _fpsWindowCount = 0;
}

#pragma mark - Session lifecycle

- (BOOL)createSessionIfPossible {
    if (!_sps || !_pps) return NO;
    NSUInteger nls = MAX(1u, MIN(_nalLengthSize, 4u));
    const uint8_t *ps[2] = {(const uint8_t *)_sps.bytes, (const uint8_t *)_pps.bytes};
    size_t sizes[2] = {_sps.length, _pps.length};

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                      2, ps, sizes, (int)nls, &fmt);
    if (st != noErr) {
        NSLog(@"[CBV2] error: CMVideoFormatDescriptionCreateFromH264ParameterSets failed: %d", (int)st);
        return NO;
    }
    if (_session) {
        VTDecompressionSessionInvalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_format) CFRelease(_format);
    _format = fmt;

    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    VTDecompressionOutputCallbackRecord cb = { CBDecodeCallback, (__bridge void *)self };
    st = VTDecompressionSessionCreate(kCFAllocatorDefault, _format, NULL,
                                      (__bridge CFDictionaryRef)attrs, &cb, &_session);
    if (st != noErr) {
        NSLog(@"[CBV2] error: VTDecompressionSessionCreate failed: %d", (int)st);
        return NO;
    }
    _pendingCount = 0;
    NSLog(@"[CBV2] H264 decoder ready (nalLengthSize=%lu)", (unsigned long)nls);
    return YES;
}

#pragma mark - NALU handling

static BOOL CBAnnexBStartCodeLen(const uint8_t *p, NSUInteger len, NSUInteger *consumed) {
    if (len >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) { *consumed = 4; return YES; }
    if (len >= 3 && p[0] == 0 && p[1] == 0 && p[2] == 1) { *consumed = 3; return YES; }
    return NO;
}

- (BOOL)pushNALU:(NSData *)nalu pts:(CMTime)pts isKeyFrame:(BOOL)keyFrame {
    if (!nalu.length) return NO;

    const uint8_t *bytes = (const uint8_t *)nalu.bytes;
    NSUInteger len = nalu.length;
    NSUInteger sc = 0;
    if (CBAnnexBStartCodeLen(bytes, len, &sc)) {
        bytes += sc;
        len -= sc;
    }
    if (len < 1) return NO;

    uint8_t type = bytes[0] & 0x1F;
    NSData *unit = [NSData dataWithBytes:bytes length:len];

    // SPS / PPS — (re)build the decoder session when both are present.
    if (type == 7) { self.sps = unit; [self createSessionIfPossible]; return YES; }
    if (type == 8) { self.pps = unit; [self createSessionIfPossible]; return YES; }
    // Non-VCL units (SEI/AUD/...): not needed for decode, not an error.
    if (type >= 6) return YES;

    if (!_session) return NO;

    // Single-NALU AVCC sample (kept for compatibility; the FLV pipeline now uses
    // decodeAccessUnit: so multi-NALU access units are submitted atomically).
    NSUInteger nls = MAX(1u, MIN(_nalLengthSize, 4u));
    NSMutableData *avcc = [NSMutableData dataWithLength:nls + len];
    uint8_t *dst = (uint8_t *)avcc.mutableBytes;
    uint32_t be = (uint32_t)len;
    for (NSUInteger i = 0; i < nls; i++) {
        dst[nls - 1 - i] = be & 0xFF;
        be >>= 8;
    }
    memcpy(dst + nls, bytes, len);
    return [self submitAVCCSample:avcc pts:pts];
}

- (BOOL)decodeAccessUnit:(NSData *)avccSample pts:(CMTime)pts isKeyFrame:(BOOL)keyFrame {
    if (!avccSample.length || !_session) return NO;
    return [self submitAVCCSample:avccSample pts:pts];
}

/// Submit one complete AVCC sample (length prefixes + NALUs) to VideoToolbox.
- (BOOL)submitAVCCSample:(NSData *)avcc pts:(CMTime)pts {
    NSUInteger nls = MAX(1u, MIN(_nalLengthSize, 4u));
    NSUInteger sampleLen = avcc.length;
    if (sampleLen < nls) return NO;

    @synchronized (self) {
        if (_pendingCount >= 12) { _droppedCount++; return YES; } // decoder too far behind
        _pendingCount++;
    }

    // Owned block buffer: allocator copies the payload so the async decode never
    // touches freed stack/heap memory after we return.
    CMBlockBufferRef bb = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, sampleLen,
                                                     kCFAllocatorDefault, NULL, 0, 0, 0, &bb);
    if (st != kCMBlockBufferNoErr) { @synchronized (self) { _pendingCount--; } return NO; }
    st = CMBlockBufferReplaceDataBytes(avcc.bytes, bb, 0, sampleLen);
    if (st != kCMBlockBufferNoErr) {
        CFRelease(bb);
        @synchronized (self) { _pendingCount--; }
        return NO;
    }

    CMSampleBufferRef sb = NULL;
    CMTime dur = CMTimeMake(1, 30);
    CMVideoFormatDescriptionRef f = _format;
    if (bb && f) {
        CMSampleTimingInfo ti = { dur, pts, kCMTimeInvalid };
        size_t size = sampleLen;
        CMSampleBufferCreateReady(kCFAllocatorDefault, bb, f, 1, 1, &ti, 1, &size, &sb);
    }
    CFRelease(bb);
    if (!sb) { @synchronized (self) { _pendingCount--; } return NO; }

    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    st = VTDecompressionSessionDecodeFrame(_session, sb, flags, NULL, NULL);
    CFRelease(sb);
    if (st == noErr) {
        @synchronized (self) { _fpsWindowCount++; }
        return YES; // async callback will decrement pendingCount
    }
    @synchronized (self) { _pendingCount--; }    // failed/bad-data frames never call back
    if (st == kVTVideoDecoderBadDataErr) return YES;
    NSLog(@"[CBV2] error: VTDecompressionSessionDecodeFrame failed status=%d", (int)st);
    return NO;
}

- (CVPixelBufferRef)copyLatestFrameWithPTS:(CMTime *)pts {
    @synchronized (self) {
        if (!_latest) return NULL;
        CVPixelBufferRef b = (CVPixelBufferRef)CFRetain(_latest);
        if (pts) *pts = _latestPTS;
        return b;
    }
}

- (BOOL)isReady {
    return _session != NULL;
}

- (void)reset {
    @synchronized (self) {
        if (_session) { VTDecompressionSessionInvalidate(_session); CFRelease(_session); _session = NULL; }
        if (_format) { CFRelease(_format); _format = NULL; }
        if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
        _sps = nil;
        _pps = nil;
        _pendingCount = 0;
        _latestPTS = kCMTimeInvalid;
        _fpsWindowStart = nil;
        _fpsWindowCount = 0;
    }
}

@end
