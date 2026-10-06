#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface CBCameraProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
- (instancetype)initWithOriginal:(id)original queue:(dispatch_queue_t)queue;
@end
