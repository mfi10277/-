# Architecture

```text
URL
 ├─ .m3u8 -> AVPlayer -> AVPlayerItemVideoOutput -> CVPixelBuffer
 └─ .flv  -> NSURLSession -> FLV parser -> AVC NALUs -> VideoToolbox -> CVPixelBuffer
                                              |
                                              v
                                       CBFrameQueue
                                              |
AVCaptureVideoDataOutput -> CBCameraProxy -> CBStreamManager
                                              |
                                    Core Image render
                                              |
                                     CMSampleBuffer
                                              |
                                         app delegate
```

The bridge deliberately keeps transport parsing separate from the camera hook. This makes it possible to replace the FLV parser or add another decoder without changing delegate interposition.

The current runtime hook is `%hook AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:`. Compatibility with private camera graphs should be added only after logs identify the concrete output node used by the target version.
