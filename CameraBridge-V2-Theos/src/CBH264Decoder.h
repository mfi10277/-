#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

/// H.264 decoder backed by VideoToolbox (VTDecompressionSession).
/// Saves the most recently decoded frame; SPS/PPS arrive as raw NALUs (type 7/8).
@interface CBH264Decoder : NSObject

/// AVCC NALU length field size in bytes (from AVCDecoderConfigurationRecord
/// lengthSizeMinusOne + 1). Default 4.
@property(nonatomic) NSUInteger nalLengthSize;

/// Push one raw H.264 NAL unit (1-byte NAL header included, no Annex-B start code).
/// Annex-B start codes are detected and stripped automatically; a blob containing
/// multiple Annex-B NALUs is split and each unit is decoded.
/// Returns YES when the unit was accepted (or stored as SPS/PPS).
- (BOOL)pushNALU:(NSData *)nalu pts:(CMTime)pts isKeyFrame:(BOOL)keyFrame;

- (CVPixelBufferRef)copyLatestFrameWithPTS:(CMTime *)pts;

- (BOOL)isReady;

/// Drop all buffered state and pending session; SPS/PPS must be re-fed afterwards.
- (void)reset;

@property(nonatomic, readonly) uint32_t decodedCount;
@property(nonatomic, readonly) uint32_t droppedCount;

@end
