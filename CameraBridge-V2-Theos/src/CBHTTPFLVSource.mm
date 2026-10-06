#import "CBHTTPFLVSource.h"
#import "CBH264Decoder.h"
#import <CoreMedia/CoreMedia.h>

@interface CBHTTPFLVSource () <NSURLSessionDataDelegate>
@property(nonatomic) NSURL *url;
@property(nonatomic, copy) CBFrameBlock frameBlock;
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSURLSessionDataTask *task;
@property(nonatomic) NSMutableData *buffer;
@property(nonatomic) CBH264Decoder *decoder;
@property(nonatomic) BOOL parsedHeader;
@property(nonatomic) NSUInteger cursor;
@property(nonatomic) NSUInteger dataOffset;
@end

@implementation CBHTTPFLVSource

- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBFrameBlock)block {
    if ((self=[super init])) {
        _url=[url copy];
        _frameBlock=[block copy];
        _buffer=[NSMutableData data];
        _decoder=[CBH264Decoder new];
    }
    return self;
}

- (void)start {
    if (_task) return;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:_url];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [req setValue:@"CameraBridgeV2/1.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    _task = [_session dataTaskWithRequest:req];
    [_task resume];
}

- (void)stop {
    [_task cancel]; _task=nil;
    [_session invalidateAndCancel]; _session=nil;
    [_buffer setLength:0];
    _parsedHeader=NO;
    _cursor=0;
    _dataOffset=0;
    [_decoder reset];
}

static inline uint32_t CBReadU24(const uint8_t *p) {
    return ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | p[2];
}
static inline uint32_t CBReadU32BE(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static inline int32_t CBReadS24BE(const uint8_t *p) {
    int32_t v=(int32_t)CBReadU24(p);
    if (v & 0x00800000) v |= (int32_t)0xFF000000;
    return v;
}

- (BOOL)parseAVCDecoderConfiguration:(const uint8_t *)p length:(NSUInteger)len {
    if (len < 7 || p[0] != 1) return NO;
    NSUInteger i=5;
    NSUInteger spsCount=p[i++] & 0x1F;
    if (spsCount == 0) return NO;

    NSData *sps=nil;
    for (NSUInteger n=0; n<spsCount; n++) {
        if (i+2 > len) return NO;
        NSUInteger l=((NSUInteger)p[i] << 8)|p[i+1];
        i += 2;
        if (i+l > len) return NO;
        if (n==0) sps=[NSData dataWithBytes:p+i length:l];
        i += l;
    }
    if (i+1 > len) return NO;
    NSUInteger ppsCount=p[i++];
    if (ppsCount == 0) return NO;

    NSData *pps=nil;
    for (NSUInteger n=0; n<ppsCount; n++) {
        if (i+2 > len) return NO;
        NSUInteger l=((NSUInteger)p[i] << 8)|p[i+1];
        i += 2;
        if (i+l > len) return NO;
        if (n==0) pps=[NSData dataWithBytes:p+i length:l];
        i += l;
    }
    if (!sps || !pps) return NO;

    [_decoder reset];
    [_decoder pushNALU:sps pts:kCMTimeZero isKeyFrame:YES];
    [_decoder pushNALU:pps pts:kCMTimeZero isKeyFrame:YES];
    return YES;
}

- (void)emitDecodedFrameWithFallbackPTS:(CMTime)pts {
    CMTime decodedPTS=kCMTimeInvalid;
    CVPixelBufferRef frame=[_decoder copyLatestFrameWithPTS:&decodedPTS];
    if (!frame) return;
    if (!CMTIME_IS_NUMERIC(decodedPTS)) decodedPTS=pts;
    if (_frameBlock) _frameBlock(frame, decodedPTS);
    CVPixelBufferRelease(frame);
}

- (void)parseVideoTag:(const uint8_t *)payload length:(NSUInteger)len timestampMS:(uint32_t)timestampMs {
    if (len < 5) return;
    uint8_t frameType=(payload[0] >> 4) & 0x0F;
    uint8_t codecId=payload[0] & 0x0F;
    if (codecId != 7) return;
    uint8_t avcPacketType=payload[1];
    int32_t compositionMS=CBReadS24BE(payload+2);
    CMTime pts=CMTimeMake((int64_t)timestampMs + compositionMS, 1000);

    if (avcPacketType == 0) {
        [self parseAVCDecoderConfiguration:payload+5 length:len-5];
        return;
    }
    if (avcPacketType != 1) return;

    const uint8_t *p=payload+5;
    NSUInteger remain=len-5;
    while (remain >= 4) {
        uint32_t naluLen=CBReadU32BE(p);
        p += 4; remain -= 4;
        if (naluLen == 0 || naluLen > remain) return;
        NSData *nalu=[NSData dataWithBytes:p length:naluLen];
        [_decoder pushNALU:nalu pts:pts isKeyFrame:(frameType==1)];
        [self emitDecodedFrameWithFallbackPTS:pts];
        p += naluLen; remain -= naluLen;
    }
}

- (void)parseAvailableFLV {
    if (_buffer.length < 9) return;
    const uint8_t *base=_buffer.bytes;
    if (!_parsedHeader) {
        if (memcmp(base,"FLV",3)!=0 || base[3] != 1) {
            [_task cancel];
            return;
        }
        uint32_t offset=CBReadU32BE(base+5);
        if (offset < 9 || offset > 1024*1024) {
            [_task cancel];
            return;
        }
        _dataOffset=offset;
        if (_buffer.length < _dataOffset+4) return;
        _cursor=_dataOffset+4;
        _parsedHeader=YES;
    }

    while (_cursor + 11 <= _buffer.length) {
        const uint8_t *p=(const uint8_t *)_buffer.bytes + _cursor;
        uint8_t tagType=p[0];
        uint32_t dataSize=CBReadU24(p+1);
        uint32_t timestamp=CBReadU24(p+4) | ((uint32_t)p[7] << 24);
        NSUInteger payloadStart=_cursor+11;
        NSUInteger tagEnd=payloadStart+(NSUInteger)dataSize+4;
        if (tagEnd > _buffer.length) break;

        const uint8_t *payload=(const uint8_t *)_buffer.bytes+payloadStart;
        if (tagType==9) [self parseVideoTag:payload length:dataSize timestampMS:timestamp];
        _cursor=tagEnd;
    }

    if (_cursor > 1024*1024 || (_cursor > 0 && _cursor*2 > _buffer.length)) {
        [_buffer replaceBytesInRange:NSMakeRange(0,_cursor) withBytes:NULL length:0];
        _cursor=0;
    }
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length==0) return;
    [_buffer appendData:data];
    [self parseAvailableFLV];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) NSLog(@"[CBV2] HTTP-FLV ended: %@", error);
    _task=nil;
    [_session finishTasksAndInvalidate];
    _session=nil;
}
@end
