#import "CBHLSSource.h"

@interface CBHLSSource ()
@property(nonatomic) AVPlayer *player;
@property(nonatomic) AVPlayerItem *item;
@property(nonatomic) AVPlayerItemVideoOutput *output;
@property(nonatomic) CADisplayLink *link;
@property(nonatomic, copy) CBHLSFrameBlock block;
@end

@implementation CBHLSSource
- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBHLSFrameBlock)block {
    if ((self=[super init])) {
        _block=[block copy];
        _item=[AVPlayerItem playerItemWithURL:url];
        NSDictionary *attrs=@{ (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA) };
        _output=[[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
        [_item addOutput:_output];
        _player=[AVPlayer playerWithPlayerItem:_item];
    }
    return self;
}
- (void)start {
    [_player play];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.link=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    });
}
- (void)stop {
    [_link invalidate]; _link=nil;
    [_player pause]; _player=nil; _item=nil; _output=nil;
}
- (void)tick:(CADisplayLink *)dl {
    if (!_output) return;
    CMTime t=[_output itemTimeForHostTime:CACurrentMediaTime()];
    if (![_output hasNewPixelBufferForItemTime:t]) return;
    CMTime actual=t;
    CVPixelBufferRef b=[_output copyPixelBufferForItemTime:t itemTimeForDisplay:&actual];
    if (b) {
        if (_block) _block(b, actual);
        CVPixelBufferRelease(b);
    }
}
@end
