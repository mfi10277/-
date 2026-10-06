#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

typedef void (^CBFrameBlock)(CVPixelBufferRef buffer, CMTime pts);

/// HTTP-FLV live source:
/// HTTP -> FLV container parser -> AVC/H.264 NALUs -> VideoToolbox -> CVPixelBuffer
@interface CBHTTPFLVSource : NSObject

- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBFrameBlock)block;

- (void)start;
- (void)stop;

@property(nonatomic, readonly) BOOL running;

@end
