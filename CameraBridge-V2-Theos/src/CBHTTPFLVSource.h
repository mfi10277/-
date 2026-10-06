#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

typedef void (^CBFrameBlock)(CVPixelBufferRef buffer, CMTime pts);

@interface CBHTTPFLVSource : NSObject
- (instancetype)initWithURL:(NSURL *)url frameBlock:(CBFrameBlock)block;
- (void)start;
- (void)stop;
@end
