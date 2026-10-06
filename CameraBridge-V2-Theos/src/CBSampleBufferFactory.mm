#import "CBSampleBufferFactory.h"

/// Build a new CMSampleBuffer from `image`, reusing the timing of `original`
/// (duration / presentationTimeStamp / decodeTimeStamp) so the app sees
/// camera-consistent timing even though pixels come from the network.
CMSampleBufferRef CBCreateSampleBufferLike(CMSampleBufferRef original, CVPixelBufferRef image) {
    if (!original || !image) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    OSStatus st = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &fmt);
    if (st != noErr) {
        NSLog(@"[CBV2] error: format description failed status=%d", (int)st);
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
    st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, fmt, &timing, &out);
    CFRelease(fmt);
    if (st != noErr || !out) {
        NSLog(@"[CBV2] error: sample buffer create failed status=%d", (int)st);
        if (out) { CFRelease(out); out = NULL; }
        return NULL;
    }
    return out;
}
