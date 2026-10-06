# V2 architecture

```text
TikTok
  |
  +-- AVCaptureVideoDataOutput
          |
          +-- CBCameraProxy
                 |
                 +-- CBStreamManager
                        |
                        +-- M3U8 -> CBHLSSource -> AVPlayer -> PixelBuffer
                        |
                        +-- FLV  -> CBHTTPFLVSource -> FLV parser -> H264Decoder
                 |
                 +-- CBFrameQueue
                 |
                 +-- CBCreateSampleBufferLike
                 |
                 +-- original camera delegate
```

## Iteration order

1. Confirm injection.
2. Confirm AVCaptureVideoDataOutput delegate hook.
3. Confirm M3U8 frame acquisition.
4. Confirm target pixel format.
5. Confirm replacement sample reaches the original delegate.
6. Implement complete FLV AVC parsing.
7. Add crop/fit/fill/rotation.
8. Add frame pacing/reconnect.
9. Only after video is stable, add audio.
