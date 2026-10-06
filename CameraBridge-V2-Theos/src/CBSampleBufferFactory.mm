#import "CBSampleBufferFactory.h"

/// Build a new CMSampleBuffer from `image`, reusing the timing of `original`
/// (duration / presentationTimeStamp / decodeTimeStamp) so the app sees
/// camera-consistent timing even though pixels come from the network.
CMSampleBufferRef CBCreateSampleBufferLike(CMSampleBufferRef original, CVPixelBufferRef image) {
    if (!original || !image) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &fmt) != noErr) {
        return NULL;
    }

    CMSampleTimingInfo timing;
    timing.duration = CMSampleBufferGetDuration(original);
    timing.presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(original);
    timing.decodeTimeStamp = CMSampleBufferGetDecodeTimeStamp(original);

    // Defensive defaults for malformed input timing.
    if (!CMTIME_IS_NUMERIC(timing.duration)) timing.duration = CMTimeMake(1, 30);
    if (!CMTIME_IS_NUMERIC(timing.presentationTimeStamp)) {
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
    }
    if (!CMTIME_IS_NUMERIC(timing.decodeTimeStamp)) timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef out = NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, fmt, &timing, &out);
    CFRelease(fmt);
    return out;
}
