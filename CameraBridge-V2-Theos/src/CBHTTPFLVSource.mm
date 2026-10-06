#import "CBHTTPFLVSource.h"
#import "CBH264Decoder.h"

typedef NS_ENUM(NSUInteger, CBFLVParseState) {
    CBFLVParseStateWaitHeader = 0,      // expecting 9-byte FLV header
    CBFLVParseStateReadPrevTagSize,     // skip PreviousTagSize0
    CBFLVParseStateReadTagHeader,       // need 11-byte tag header
    CBFLVParseStateReadTagPayload,      // need tag payload + PreviousTagSize
    CBFLVParseStateProcessTag,          // dispatch tag
};

/// A network chunk does NOT map 1:1 to an FLV tag. We accumulate bytes into
/// _buffer and only advance _cursor past complete tags; an incomplete tag simply
/// waits for the next didReceiveData: batch.
@interface CBHTTPFLVSource () <NSURLSessionDataDelegate>
@property(nonatomic) NSURL *url;
@property(nonatomic, copy) CBFrameBlock frameBlock;
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSURLSessionDataTask *task;
@property(nonatomic) NSMutableData *buffer;
@property(nonatomic) CBH264Decoder *decoder;

@property(nonatomic) CBFLVParseState state;
@property(nonatomic) NSUInteger cursor;
@property(nonatomic) NSUInteger dataOffset;      // from FLV header

@property(nonatomic) uint8_t currentTagType;
@property(nonatomic) uint32_t currentTagSize;
@property(nonatomic) uint32_t currentTagTimestamp;

@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL reconnectScheduled;
@property(nonatomic) NSUInteger reconnectCount;
@property(nonatomic) NSTimeInterval reconnectDelay;

@property(nonatomic) uint64_t parsedTags;
@property(nonatomic) uint64_t videoTags;
@property(nonatomic) uint64_t audioTags;         // skipped in v1, counted only
@property(nonatomic) uint64_t skippedAudioBytes;

@property(nonatomic) CMTime lastEmittedPTS;
@property(nonatomic) BOOL lastEmittedPTSValid;
@end

@implementation CBHTTPFLVSource

- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBFrameBlock)block {
    if ((self = [super init])) {
        _url = [url copy];
        _frameBlock = [block copy];
        _buffer = [NSMutableData data];
        _decoder = [CBH264Decoder new];
        _cursor = 0;
        _state = CBFLVParseStateWaitHeader;
        _stopped = YES;
        _reconnectDelay = 2.0;
        _lastEmittedPTSValid = NO;
    }
    return self;
}

- (BOOL)running {
    return _task != nil;
}

#pragma mark - Lifecycle

- (void)start {
    if (_task) return;
    _stopped = NO;
    _reconnectScheduled = NO;
    _reconnectCount = 0;
    _reconnectDelay = 2.0;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;      // gap between data packets
    cfg.timeoutIntervalForResource = 0;      // live stream: never end by idle
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    cfg.waitsForConnectivity = NO;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:_url];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"CameraBridgeV2/1.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    _task = [_session dataTaskWithRequest:req];
    [_task resume];
    NSLog(@"[CBV2] HTTP-FLV connecting: %@", _url.absoluteString);
}

- (void)stop {
    _stopped = YES;
    [_task cancel];
    _task = nil;
    [_session invalidateAndCancel];
    _session = nil;
    [self resetStreamState];
    NSLog(@"[CBV2] HTTP-FLV stopped");
}

- (void)resetStreamState {
    [_buffer setLength:0];
    _cursor = 0;
    _state = CBFLVParseStateWaitHeader;
    _dataOffset = 0;
    _parsedTags = 0;
    _videoTags = 0;
    _audioTags = 0;
    _skippedAudioBytes = 0;
    _lastEmittedPTSValid = NO;
    [_decoder reset];
    NSLog(@"[CBV2] decoder reset");
}

- (void)scheduleReconnect {
    if (_stopped || _reconnectScheduled) return;
    _reconnectScheduled = YES;
    _reconnectCount++;
    NSTimeInterval delay = _reconnectDelay;
    _reconnectDelay = MIN(_reconnectDelay * 2.0, 15.0);
    NSLog(@"[CBV2] HTTP-FLV reconnect in %.0fs (attempt %lu)", delay, (unsigned long)_reconnectCount);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        self->_reconnectScheduled = NO;
        if (self->_stopped) return;
        [self resetStreamState];
        [self start];
    });
}

- (void)failWithReason:(NSString *)reason {
    NSLog(@"[CBV2] error: HTTP-FLV %@", reason);
    [_task cancel];
    _task = nil;
    [_session invalidateAndCancel];
    _session = nil;
    if (!_stopped) [self scheduleReconnect];
}

#pragma mark - Byte helpers

static inline uint32_t CBReadU24(const uint8_t *p) {
    return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2];
}

static inline uint32_t CBReadU32BE(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static inline int32_t CBReadS24BE(const uint8_t *p) {
    int32_t v = (int32_t)CBReadU24(p);
    if (v & 0x00800000) v |= 0xFF000000;
    return v;
}

#pragma mark - AVC configuration

- (BOOL)parseAVCDecoderConfiguration:(const uint8_t *)p length:(NSUInteger)len {
    if (len < 7 || p[0] != 1) return NO;

    // configurationVersion(1) profile(1) compatibility(1) level(1) lengthSizeMinusOne(1)
    self.decoder.nalLengthSize = (p[4] & 0x03) + 1;

    NSUInteger i = 5;
    NSUInteger spsCount = p[i++] & 0x1F;
    if (spsCount == 0) return NO;
    NSData *sps = nil;
    for (NSUInteger n = 0; n < spsCount; n++) {
        if (i + 2 > len) return NO;
        NSUInteger l = ((NSUInteger)p[i] << 8) | p[i + 1];
        i += 2;
        if (i + l > len) return NO;
        if (n == 0) sps = [NSData dataWithBytes:p + i length:l];
        i += l;
    }
    if (!sps) return NO;

    if (i + 1 > len) return NO;
    NSUInteger ppsCount = p[i++];
    if (ppsCount == 0) return NO;
    NSData *pps = nil;
    for (NSUInteger n = 0; n < ppsCount; n++) {
        if (i + 2 > len) return NO;
        NSUInteger l = ((NSUInteger)p[i] << 8) | p[i + 1];
        i += 2;
        if (i + l > len) return NO;
        if (n == 0) pps = [NSData dataWithBytes:p + i length:l];
        i += l;
    }
    if (!pps) return NO;

    [_decoder reset];
    [_decoder pushNALU:sps pts:kCMTimeZero isKeyFrame:YES];
    [_decoder pushNALU:pps pts:kCMTimeZero isKeyFrame:YES];
    NSLog(@"[CBV2] AVC config parsed (sps=%lu pps=%lu nalLength=%lu)",
          (unsigned long)sps.length, (unsigned long)pps.length, (unsigned long)self.decoder.nalLengthSize);
    NSLog(@"[CBV2] SPS received");
    NSLog(@"[CBV2] PPS received");
    return YES;
}

#pragma mark - Frame emission

- (void)emitDecodedFrameWithFallbackPTS:(CMTime)pts {
    CMTime decodedPTS = kCMTimeInvalid;
    CVPixelBufferRef frame = [_decoder copyLatestFrameWithPTS:&decodedPTS];
    if (!frame) return;
    if (!CMTIME_IS_NUMERIC(decodedPTS)) decodedPTS = pts;

    // Dedupe: only forward when the decoder actually produced a newer frame.
    if (_lastEmittedPTSValid && CMTimeCompare(decodedPTS, _lastEmittedPTS) == 0) {
        CVPixelBufferRelease(frame);
        return;
    }
    _lastEmittedPTS = decodedPTS;
    _lastEmittedPTSValid = YES;

    if (_frameBlock) _frameBlock(frame, decodedPTS);
    CVPixelBufferRelease(frame);
}

- (void)parseVideoTag:(const uint8_t *)payload length:(NSUInteger)len timestampMS:(uint32_t)timestampMs {
    if (len < 5) return;
    _videoTags++;

    uint8_t frameType = (payload[0] >> 4) & 0x0F;
    uint8_t codecId = payload[0] & 0x0F;
    if (codecId != 7) return; // AVC/H.264 only

    uint8_t avcPacketType = payload[1];
    int32_t compositionMS = CBReadS24BE(payload + 2);
    CMTime pts = CMTimeMake((int64_t)timestampMs + compositionMS, 1000);

    if (avcPacketType == 0) { // AVC sequence header
        [self parseAVCDecoderConfiguration:payload + 5 length:len - 5];
        return;
    }
    if (avcPacketType != 1) return; // 2 = end of sequence

    NSUInteger nls = self.decoder.nalLengthSize;
    if (nls < 1 || nls > 4) nls = 4;
    const uint8_t *p = payload + 5;
    NSUInteger remain = len - 5;
    BOOL keyFrame = (frameType == 1);
    BOOL emitted = NO;

    while (remain >= nls) {
        uint32_t naluLen = 0;
        for (NSUInteger i = 0; i < nls; i++) naluLen = (naluLen << 8) | p[i];
        p += nls;
        remain -= nls;
        if (naluLen == 0) continue;
        if (naluLen > remain) {
            NSLog(@"[CBV2] error: truncated NALU in video tag (len=%u remain=%lu)", naluLen, (unsigned long)remain);
            break;
        }
        NSData *nalu = [NSData dataWithBytes:p length:naluLen];
        uint8_t naluType = ((const uint8_t *)nalu.bytes)[0] & 0x1F;
        BOOL accepted = [_decoder pushNALU:nalu pts:pts isKeyFrame:keyFrame];
        p += naluLen;
        remain -= naluLen;

        // Emit at most once per access unit, and only after a VCL NALU was pushed.
        if (!emitted && naluType >= 1 && naluType <= 5 && accepted) {
            emitted = YES;
            [self emitDecodedFrameWithFallbackPTS:pts];
        }
    }
}

#pragma mark - FLV parser (state machine)

- (void)parseAvailableFLV {
    const uint8_t *bytes = (const uint8_t *)_buffer.bytes;
    NSUInteger len = _buffer.length;
    BOOL progress = YES;
    while (progress) {
        progress = NO;
        switch (_state) {
            case CBFLVParseStateWaitHeader: {
                if (len - _cursor < 9) return;
                const uint8_t *p = bytes + _cursor;
                if (memcmp(p, "FLV", 3) != 0 || p[3] != 1) {
                    [self failWithReason:@"bad FLV signature"];
                    return;
                }
                uint32_t offset = CBReadU32BE(p + 5);
                if (offset < 9 || offset > 1024 * 1024) {
                    [self failWithReason:@"bad FLV data offset"];
                    return;
                }
                _dataOffset = offset;
                _cursor += 9;
                _state = CBFLVParseStateReadPrevTagSize;
                progress = YES;
                NSLog(@"[CBV2] FLV header parsed (dataOffset=%u)", offset);
                break;
            }
            case CBFLVParseStateReadPrevTagSize: {
                if (len - _cursor < 4) return;
                _cursor += 4; // PreviousTagSize0
                _state = CBFLVParseStateReadTagHeader;
                progress = YES;
                break;
            }
            case CBFLVParseStateReadTagHeader: {
                if (len - _cursor < 11) return;
                const uint8_t *p = bytes + _cursor;
                _currentTagType = p[0];
                _currentTagSize = CBReadU24(p + 1);
                _currentTagTimestamp = CBReadU24(p + 4) | ((uint32_t)p[7] << 24);
                if (_currentTagSize > 24 * 1024 * 1024) {
                    [self failWithReason:@"tag too large"];
                    return;
                }
                _state = CBFLVParseStateReadTagPayload;
                progress = YES;
                break;
            }
            case CBFLVParseStateReadTagPayload: {
                // payload + PreviousTagSize must be fully buffered
                if (len - _cursor < 11 + _currentTagSize + 4) return;
                _state = CBFLVParseStateProcessTag;
                progress = YES;
                break;
            }
            case CBFLVParseStateProcessTag: {
                [self processTagAtCursor];
                _cursor += 11 + _currentTagSize + 4;
                _state = CBFLVParseStateReadTagHeader;
                progress = YES;
                break;
            }
        }
    }
    [self compactBuffer];
}

- (void)processTagAtCursor {
    _parsedTags++;
    const uint8_t *payload = (const uint8_t *)_buffer.bytes + _cursor + 11;
    switch (_currentTagType) {
        case 9: // video
            [self parseVideoTag:payload length:_currentTagSize timestampMS:_currentTagTimestamp];
            break;
        case 8: // audio — v1 deliberately skips audio; must never break the parser
            _audioTags++;
            _skippedAudioBytes += _currentTagSize;
            break;
        case 18: // script data — ignored
        default:
            break;
    }
}

- (void)compactBuffer {
    if (_cursor == 0) return;
    // Free parsed bytes; keep an incomplete tag tail.
    if (_cursor > 1024 * 1024 || _cursor * 2 > _buffer.length) {
        [_buffer replaceBytesInRange:NSMakeRange(0, _cursor) withBytes:NULL length:0];
        _cursor = 0;
    }
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)s
        dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (http.statusCode != 200) {
            // Cancel triggers didCompleteWithError:, which schedules the reconnect once.
            NSLog(@"[CBV2] error: HTTP-FLV bad status %ld", (long)http.statusCode);
            completionHandler(NSURLSessionResponseCancel);
            return;
        }
    }
    NSLog(@"[CBV2] HTTP-FLV connected");
    _reconnectCount = 0;
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s
        dataTask:(NSURLSessionDataTask *)task
  didReceiveData:(NSData *)data {
    if (!data.length) return;
    [_buffer appendData:data];
    if (_buffer.length > 48 * 1024 * 1024) {
        [self failWithReason:@"buffer overflow (48MB cap)"];
        return;
    }
    [self parseAvailableFLV];
}

- (void)URLSession:(NSURLSession *)s
        task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    _task = nil;
    [_session finishTasksAndInvalidate];
    _session = nil;
    if (_stopped) return;
    if (error) {
        NSLog(@"[CBV2] HTTP-FLV stream ended: %@", error.localizedDescription);
    } else {
        NSLog(@"[CBV2] HTTP-FLV stream ended (EOF)");
    }
    [self scheduleReconnect];
}

@end
