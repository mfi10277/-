#import "CBSampleBufferFactory.h"

CMSampleBufferRef CBCreateSampleBufferLike(CMSampleBufferRef original, CVPixelBufferRef image) {
    if (!original || !image) return NULL;
    CMVideoFormatDescriptionRef fmt=NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,image,&fmt)!=noErr) return NULL;
    CMSampleTimingInfo timing;
    timing.duration=CMSampleBufferGetDuration(original);
    timing.presentationTimeStamp=CMSampleBufferGetPresentationTimeStamp(original);
    timing.decodeTimeStamp=CMSampleBufferGetDecodeTimeStamp(original);
    CMSampleBufferRef out=NULL;
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,image,fmt,&timing,&out);
    CFRelease(fmt);
    return out;
}
