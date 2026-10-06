#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

typedef void (^CBHLSFrameBlock)(CVPixelBufferRef buffer, CMTime pts);

/// M3U8 / HLS live source:
/// M3U8 -> AVPlayer -> AVPlayerItemVideoOutput -> CVPixelBuffer
@interface CBHLSSource : NSObject

- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBHLSFrameBlock)block;

- (void)start;
- (void)stop;

@property(nonatomic, readonly) BOOL running;

@end
