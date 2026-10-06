#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

typedef void (^CBHLSFrameBlock)(CVPixelBufferRef buffer, CMTime pts);

@interface CBHLSSource : NSObject
- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBHLSFrameBlock)block;
- (void)start;
- (void)stop;
@end
