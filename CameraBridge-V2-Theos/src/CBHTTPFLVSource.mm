#import "CBHTTPFLVSource.h"
#import "CBH264Decoder.h"

@interface CBHTTPFLVSource () <NSURLSessionDataDelegate>
@property(nonatomic) NSURL *url;
@property(nonatomic, copy) CBFrameBlock frameBlock;
@property(nonatomic) NSURLSession *session;
@property(nonatomic) NSURLSessionDataTask *task;
@property(nonatomic) NSMutableData *buffer;
@property(nonatomic) CBH264Decoder *decoder;
@property(nonatomic) uint64_t basePTS;
@end

@implementation CBHTTPFLVSource

- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBFrameBlock)block {
    if ((self=[super init])) {
        _url=url; _frameBlock=[block copy]; _buffer=[NSMutableData data]; _decoder=[CBH264Decoder new];
    }
    return self;
}
- (void)start {
    if (_task) return;
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15;
    _session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    _task = [_session dataTaskWithURL:_url];
    [_task resume];
}
- (void)stop {
    [_task cancel]; _task=nil;
    [_session invalidateAndCancel]; _session=nil;
    [_buffer setLength:0];
    [_decoder reset];
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [_buffer appendData:data];
    [self parseAvailableFLV];
}
- (void)parseAvailableFLV {
    // Minimal scaffold: validates FLV header and exposes parser extension point.
    // Full AMF/script-tag parsing and AVC packet extraction belongs in the next iteration.
    if (_buffer.length < 13) return;
    const uint8_t *p=_buffer.bytes;
    if (memcmp(p,"FLV",3)!=0) {
        [_task cancel]; return;
    }
    // Keep the stream buffered rather than pretending to decode an incomplete FLV.
    // This class is deliberately isolated so the parser can be upgraded without touching camera hooks.
}
@end
