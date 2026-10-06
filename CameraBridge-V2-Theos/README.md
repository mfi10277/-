# CameraBridge V2

Standalone iOS video-source replacement tweak for testing on a user-owned app.

## Target

- iPhone 11
- iOS 15.3.1
- TrollStore + TrollFools
- Intended first target: TikTok 47.0.0

## Important

V2 deliberately does **not** reproduce the original plugin's license/card-key system.
It is an independent implementation.

## Current source paths

1. M3U8 -> AVPlayerItemVideoOutput -> CVPixelBuffer
2. HTTP-FLV -> isolated parser scaffold -> H264 VideoToolbox decoder
3. Frame queue
4. Pixel-buffer conversion
5. AVCaptureVideoDataOutput delegate proxy
6. CMSampleBuffer replacement
7. Simple URL input UI

### HTTP-FLV status

The FLV transport class is intentionally isolated. The supplied Douyin test URL is HTTP-FLV, not M3U8.
The parser scaffold validates the FLV header but does not yet implement complete FLV AVC tag parsing.
Therefore **M3U8 is the first end-to-end path in this ZIP**; HTTP-FLV is the next parser task.

## Build

### GitHub Actions

Push the project to GitHub and run:
Actions -> Build CameraBridge V2.

The workflow produces:
- CameraBridgeV2 rootless .deb
- source archive

### Local

On a macOS/Theos environment:

```sh
export THEOS=~/theos
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
```

## TrollFools

Inject the built tweak/dylib into the target app using your normal TrollFools workflow.
If the app crashes, remove the injection and inspect device logs before changing hooks.

## First test

Use an M3U8 URL first. Then check logs:

[CBV2] injected
[CBV2] camera delegate hooked
[CBV2] stream started
