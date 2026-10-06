#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface CBH264Decoder : NSObject
- (BOOL)pushNALU:(NSData *)nalu pts:(CMTime)pts isKeyFrame:(BOOL)keyFrame;
- (CVPixelBufferRef)copyLatestFrameWithPTS:(CMTime *)pts;
- (void)reset;
@end
