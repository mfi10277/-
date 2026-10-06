#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface CBFrameQueue : NSObject
- (void)push:(CVPixelBufferRef)buffer pts:(CMTime)pts;
- (CVPixelBufferRef)copyLatestForTargetSize:(CGSize)size pts:(CMTime *)pts;
- (void)clear;
@end
