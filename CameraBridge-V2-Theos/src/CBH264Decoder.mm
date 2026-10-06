#import "CBH264Decoder.h"
#import <VideoToolbox/VideoToolbox.h>

@interface CBH264Decoder ()
@property(nonatomic) CMVideoFormatDescriptionRef format;
@property(nonatomic) VTDecompressionSessionRef session;
@property(nonatomic) CVPixelBufferRef latest;
@property(nonatomic) CMTime latestPTS;
@property(nonatomic) NSData *sps;
@property(nonatomic) NSData *pps;
@end

@implementation CBH264Decoder

static void CBDecodeCallback(void *decompressionOutputRefCon,
                             void *sourceFrameRefCon,
                             OSStatus status,
                             VTDecodeInfoFlags infoFlags,
                             CVImageBufferRef imageBuffer,
                             CMTime presentationTimeStamp,
                             CMTime presentationDuration) {
    CBH264Decoder *self = (__bridge CBH264Decoder *)decompressionOutputRefCon;
    if (status != noErr || !imageBuffer) return;
    @synchronized (self) {
        if (self.latest) CVPixelBufferRelease(self.latest);
        self.latest = (CVPixelBufferRef)CFRetain(imageBuffer);
        self.latestPTS = presentationTimeStamp;
    }
}

- (void)dealloc { [self reset]; }

- (BOOL)createSessionIfPossible {
    if (!_sps || !_pps) return NO;
    const uint8_t *ps[2] = {_sps.bytes, _pps.bytes};
    size_t sizes[2] = {_sps.length, _pps.length};
    if (_format) CFRelease(_format);
    OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, ps, sizes, 4, &_format);
    if (st != noErr) return NO;

    if (_session) { VTDecompressionSessionInvalidate(_session); CFRelease(_session); _session = NULL; }
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VTDecompressionOutputCallbackRecord cb = { CBDecodeCallback, (__bridge void *)self };
    st = VTDecompressionSessionCreate(kCFAllocatorDefault, _format, NULL, (__bridge CFDictionaryRef)attrs, &cb, &_session);
    return st == noErr;
}

- (BOOL)pushNALU:(NSData *)nalu pts:(CMTime)pts isKeyFrame:(BOOL)keyFrame {
    if (!nalu.length) return NO;
    const uint8_t *p = nalu.bytes;
    uint8_t type = p[0] & 0x1F;
    if (type == 7) { self.sps = nalu; [self createSessionIfPossible]; return YES; }
    if (type == 8) { self.pps = nalu; [self createSessionIfPossible]; return YES; }
    if (!_session) return NO;

    NSMutableData *avcc = [NSMutableData dataWithLength:4 + nalu.length];
    uint32_t len = (uint32_t)CFSwapInt32HostToBig((uint32_t)nalu.length);
    memcpy(avcc.mutableBytes, &len, 4);
    memcpy((uint8_t *)avcc.mutableBytes + 4, nalu.bytes, nalu.length);

    CMBlockBufferRef bb = NULL;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, avcc.mutableBytes, avcc.length,
                                       kCFAllocatorNull, NULL, 0, avcc.length, 0, &bb);
    CMSampleBufferRef sb = NULL;
    CMTime dur = CMTimeMake(1, 30);
    if (bb && _format) {
        CMSampleTimingInfo ti = {dur, pts, kCMTimeInvalid};
        size_t size = avcc.length;
        CMSampleBufferCreateReady(kCFAllocatorDefault, bb, _format, 1, 1, &ti, 1, &size, &sb);
    }
    if (bb) CFRelease(bb);
    if (!sb) return NO;
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    OSStatus st = VTDecompressionSessionDecodeFrame(_session, sb, flags, NULL, NULL);
    CFRelease(sb);
    return st == noErr || st == kVTVideoDecoderBadDataErr;
}

- (CVPixelBufferRef)copyLatestFrameWithPTS:(CMTime *)pts {
    @synchronized (self) {
        if (!_latest) return NULL;
        CVPixelBufferRef b = (CVPixelBufferRef)CFRetain(_latest);
        if (pts) *pts = _latestPTS;
        return b;
    }
}

- (void)reset {
    @synchronized (self) {
        if (_session) { VTDecompressionSessionInvalidate(_session); CFRelease(_session); _session = NULL; }
        if (_format) { CFRelease(_format); _format = NULL; }
        if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
        _sps = nil; _pps = nil;
    }
}
@end
