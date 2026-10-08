#import "CBHLSSource.h"

// HLS URLs can carry signed query parameters; do not expose them in syslog.
static NSString *CBURLLabel(NSURL *url) {
    if (!url.host.length) return @"(no host)";
    return [NSString stringWithFormat:@"%@://%@", url.scheme ?: @"?", url.host];
}

@interface CBHLSSource ()
@property(nonatomic) NSURL *url;
@property(nonatomic) AVPlayer *player;
@property(nonatomic) AVPlayerItem *item;
@property(nonatomic) AVPlayerItemVideoOutput *output;
@property(nonatomic) CADisplayLink *link;
@property(nonatomic, copy) CBHLSFrameBlock block;

@property(nonatomic) BOOL stopped;
@property(nonatomic) BOOL observing;
@property(nonatomic) BOOL reconnectScheduled;
@property(nonatomic) NSUInteger reconnectCount;
@property(nonatomic) NSTimeInterval reconnectDelay;
@end

@implementation CBHLSSource

- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBHLSFrameBlock)block {
    if ((self = [super init])) {
        _url = [url copy];
        _block = [block copy];
        _stopped = YES;
        _reconnectDelay = 2.0;
        [self buildPipelineWithURL:_url];
    }
    return self;
}

- (BOOL)running {
    return _player != nil;
}

- (void)buildPipelineWithURL:(NSURL *)url {
    [self teardownPipeline];
    _item = [AVPlayerItem playerItemWithURL:url];
    NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
    _output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
    [_item addOutput:_output];
    [_output requestNotificationOfMediaDataChangeWithAdvanceInterval:0.1];
    _player = [AVPlayer playerWithPlayerItem:_item];
    _player.automaticallyWaitsToMinimizeStalling = NO;
    [self observeItem];
}

- (void)observeItem {
    if (_observing || !_item) return;
    _observing = YES;
    [_item addObserver:self forKeyPath:@"status" options:NSKeyValueObservingOptionNew context:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemFailed:)
                                                 name:AVPlayerItemFailedToPlayToEndTimeNotification
                                               object:_item];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemStalled:)
                                                 name:AVPlayerItemPlaybackStalledNotification
                                               object:_item];
}

- (void)removeItemObservation {
    if (!_observing) return;
    _observing = NO;
    @try {
        [_item removeObserver:self forKeyPath:@"status"];
    } @catch (NSException *e) {
        // already removed
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                  object:_item];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:AVPlayerItemPlaybackStalledNotification
                                                  object:_item];
}

- (void)teardownPipeline {
    [self removeItemObservation];
    [_player pause];
    _player = nil;
    _item = nil;
    _output = nil;
}

- (void)dealloc {
    [self removeItemObservation];
}

#pragma mark - Lifecycle

- (void)start {
    _stopped = NO;
    _reconnectCount = 0;
    _reconnectDelay = 2.0;
    [self startPlayer];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_stopped) return;
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    });
}

- (void)startPlayer {
    if (_player) [_player play];
    NSLog(@"[CBV2] HLS started: %@", CBURLLabel(_url));
}

- (void)stop {
    _stopped = YES;
    [_link invalidate];
    _link = nil;
    [self teardownPipeline];
    NSLog(@"[CBV2] HLS stopped");
}

- (void)scheduleReconnect {
    if (_stopped || _reconnectScheduled) return;
    _reconnectScheduled = YES;
    _reconnectCount++;
    NSTimeInterval delay = _reconnectDelay;
    _reconnectDelay = MIN(_reconnectDelay * 2.0, 15.0);
    NSLog(@"[CBV2] HLS reconnect in %.0fs (attempt %lu)", delay, (unsigned long)_reconnectCount);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_reconnectScheduled = NO;
        if (self->_stopped) return;
        [self buildPipelineWithURL:self->_url];
        [self startPlayer];
    });
}

#pragma mark - Item observation

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == _item && [keyPath isEqualToString:@"status"]) {
        if (_item.status == AVPlayerItemStatusFailed) {
            NSLog(@"[CBV2] error: HLS item failed: %@", _item.error.localizedDescription ?: @"unknown");
            [self scheduleReconnect];
        } else if (_item.status == AVPlayerItemStatusReadyToPlay) {
            NSLog(@"[CBV2] HLS ready to play");
        }
    }
}

- (void)itemFailed:(NSNotification *)note {
    NSLog(@"[CBV2] error: HLS failed to play to end");
    [self scheduleReconnect];
}

- (void)itemStalled:(NSNotification *)note {
    // Live HLS frequently stalls briefly; AVPlayer recovers by itself.
    NSLog(@"[CBV2] HLS playback stalled");
}

#pragma mark - Frame pull

- (void)tick:(CADisplayLink *)dl {
    if (!_output) return;
    CMTime t = [_output itemTimeForHostTime:CACurrentMediaTime()];
    if (![_output hasNewPixelBufferForItemTime:t]) return;
    CMTime actual = t;
    CVPixelBufferRef b = [_output copyPixelBufferForItemTime:t itemTimeForDisplay:&actual];
    if (b) {
        if (_block) _block(b, actual);
        CVPixelBufferRelease(b);
    }
}

@end
