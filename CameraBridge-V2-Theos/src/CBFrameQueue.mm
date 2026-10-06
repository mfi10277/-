#import "CBFrameQueue.h"

@interface CBFrameItem : NSObject
@property(nonatomic) CVPixelBufferRef buffer;
@property(nonatomic) CMTime pts;
@end
@implementation CBFrameItem
- (void)dealloc {
    if (_buffer) CVPixelBufferRelease(_buffer);
}
@end

@implementation CBFrameQueue {
    NSMutableArray<CBFrameItem *> *_items;
    dispatch_queue_t _lock;
    NSUInteger _maxCount;
}

- (instancetype)init {
    return [self initWithMaxCount:3];
}

- (instancetype)initWithMaxCount:(NSUInteger)maxCount {
    if ((self = [super init])) {
        _maxCount = MAX(maxCount, 1);
        _items = [NSMutableArray array];
        _lock = dispatch_queue_create("com.camerabridge.framequeue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)push:(CVPixelBufferRef)b pts:(CMTime)p {
    if (!b) return;
    CVPixelBufferRetain(b);
    dispatch_async(_lock, ^{
        CBFrameItem *i = [CBFrameItem new];
        i.buffer = b;
        i.pts = p;
        [_items addObject:i];
        // Bounded queue: keep the newest frames, drop the oldest.
        while (_items.count > _maxCount) {
            [_items removeObjectAtIndex:0];
        }
    });
}

- (CVPixelBufferRef)copyLatestForTargetSize:(CGSize)size pts:(CMTime *)pts {
    __block CVPixelBufferRef out = NULL;
    dispatch_sync(_lock, ^{
        CBFrameItem *i = _items.lastObject;
        if (i) {
            out = i.buffer;
            CVPixelBufferRetain(out);
            if (pts) *pts = i.pts;
        }
    });
    return out;
}

- (void)clear {
    dispatch_sync(_lock, ^{
        [_items removeAllObjects];
    });
}

- (NSUInteger)count {
    __block NSUInteger c = 0;
    dispatch_sync(_lock, ^{
        c = _items.count;
    });
    return c;
}

@end
