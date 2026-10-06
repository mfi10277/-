#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>

/// H.264 decoder backed by VideoToolbox (VTDecompressionSession).
/// Saves the most recently decoded frame; SPS/PPS arrive as raw NALUs (type 7/8).
@interface CBH264Decoder : NSObject

/// AVCC NALU length field size in bytes (from AVCDecoderConfigurationRecord
/// lengthSizeMinusOne + 1). Default 4.
@property(nonatomic) NSUInteger nalLengthSize;

/// Invoked on the VideoToolbox decode callback thread for every successfully
/// decoded frame (pixel buffer + presentation time). Set by the FLV source so a
/// decoded access unit is pushed downstream immediately.
@property(nonatomic, copy) void (^onFrameDecoded)(CVPixelBufferRef frame, CMTime pts);

/// Push one raw H.264 NAL unit (1-byte NAL header included, no Annex-B start code).
/// Annex-B start codes are detected and stripped automatically; a blob containing
/// multiple Annex-B NALUs is split and each unit is decoded.
/// Returns YES when the unit was accepted (or stored as SPS/PPS).
- (BOOL)pushNALU:(NSData *)nalu pts:(CMTime)pts isKeyFrame:(BOOL)keyFrame;

/// Decode one complete access unit given as an AVCC sample: a concatenation of
/// (nalLengthSize-byte length prefix + NALU) blocks covering every NALU of the AU.
/// This is the correct unit for VideoToolbox — multiple slice NALUs of one frame
/// must live in a single sample buffer, never be split into separate decodes.
/// Returns YES when the AU was accepted for decoding.
- (BOOL)decodeAccessUnit:(NSData *)avccSample pts:(CMTime)pts isKeyFrame:(BOOL)keyFrame;

- (CVPixelBufferRef)copyLatestFrameWithPTS:(CMTime *)pts;

- (BOOL)isReady;

/// Drop all buffered state and pending session; SPS/PPS must be re-fed afterwards.
- (void)reset;

@property(nonatomic, readonly) uint32_t decodedCount;
@property(nonatomic, readonly) uint32_t droppedCount;

@end
