#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

/// Bounded, thread-safe latest-frame queue.
/// Network producer pushes; camera callback pops the newest frame without waiting on the network.
@interface CBFrameQueue : NSObject

- (instancetype)initWithMaxCount:(NSUInteger)maxCount;

- (void)push:(CVPixelBufferRef)buffer pts:(CMTime)pts;
- (CVPixelBufferRef)copyLatestForTargetSize:(CGSize)size pts:(CMTime *)pts;
- (void)clear;
- (NSUInteger)count;

@end
