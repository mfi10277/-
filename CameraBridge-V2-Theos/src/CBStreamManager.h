#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

@interface CBStreamManager : NSObject
+ (instancetype)shared;
- (void)startIfNeeded;
- (void)stop;
- (void)restart;
- (BOOL)isStarted;
- (CVPixelBufferRef)copyLatestFrameForTarget:(CVPixelBufferRef)target pts:(CMTime *)pts;

/// Diagnostic source state (CBV2.SourceState): NO_URL / CONNECTING / CONNECTED /
/// NO_VIDEO / DECODING / FRAME_READY / INJECTING / ERROR.
+ (void)updateSourceState:(NSString *)state;
+ (NSString *)sourceState;
@end
