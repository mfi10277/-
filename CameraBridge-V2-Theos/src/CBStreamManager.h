#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface CBStreamManager : NSObject
+ (instancetype)shared;
- (void)startIfNeeded;
- (void)stop;
- (CVPixelBufferRef)copyLatestFrameForTarget:(CVPixelBufferRef)target pts:(CMTime *)pts;
@end
