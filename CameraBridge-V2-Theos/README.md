# CameraBridge V2

Theos rootless iOS tweak that replaces an app's `AVCaptureVideoDataOutput` camera frames with frames decoded from a user-supplied network stream (HTTP-FLV or M3U8/HLS).

Target environment: **iPhone 11 / iOS 15.3.1 / TrollStore / TrollFools**, injected into **TikTok v47.0.0 (`com.zhiliaoapp.musically`)**.

## Pipeline

```text
HTTP-FLV:  HTTP -> FLV parser -> AVC SPS/PPS -> H.264 NALUs -> VideoToolbox -> CVPixelBuffer
HLS:       M3U8 -> AVPlayer -> AVPlayerItemVideoOutput -> CVPixelBuffer
                                                          |
                                                          v
                                                    CBFrameQueue (latest, bounded 3)
                                                          |
AVCaptureVideoDataOutput -> CBCameraProxy -> CBStreamManager
                                                          |
                                               Core Image render
                                              (Fill/Fit/Stretch + Mirror + Rotation)
                                                          |
                                                     CMSampleBuffer
                                                          |
                                                   original delegate
```

## Repository layout

```text
CameraBridge-V2-Theos/
├── Makefile
├── control
├── README.md
├── docs/
│   └── ARCHITECTURE.md
├── src/
│   ├── main.xm
│   ├── CBSettings.h / CBSettings.mm
│   ├── CBFrameQueue.h / CBFrameQueue.mm
│   ├── CBH264Decoder.h / CBH264Decoder.mm
│   ├── CBHTTPFLVSource.h / CBHTTPFLVSource.mm
│   ├── CBHLSSource.h / CBHLSSource.mm
│   ├── CBStreamManager.h / CBStreamManager.mm
│   ├── CBCameraProxy.h / CBCameraProxy.mm
│   ├── CBSampleBufferFactory.h / CBSampleBufferFactory.mm
│   └── CBControlPanel.h / CBControlPanel.mm
├── layout/
│   └── Library/MobileSubstrate/DynamicLibraries/CameraBridgeV2.plist
└── .github/workflows/build.yml
```

## Build

### GitHub Actions (recommended)

Push to `main` or run the `Build CameraBridge V2` workflow manually (`workflow_dispatch`). The runner:

1. sets up Theos + iOS SDK on `macos-latest`
2. `make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless`
3. uploads `artifacts/` containing `.deb` and per-arch `.dylib` files

### Local (macOS with Theos)

```sh
make clean
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
# artifacts:
#   packages/*.deb
#   .theos/obj/arm64/CameraBridgeV2.dylib  (or .theos/obj/debug/arm64/...)
#   .theos/obj/arm64e/CameraBridgeV2.dylib
```

Windows cannot build iOS binaries — use the GitHub Action or a macOS machine.

## Install on device (TrollFools)

1. Build or download `CameraBridgeV2.dylib` (arm64 for iPhone 11).
2. Open **TrollFools**, select **TikTok** (`com.zhiliaoapp.musically`), inject the dylib.
3. Relaunch TikTok. After 2 s the CameraBridge panel appears **on every launch** (independent of whether a URL is already configured).
4. The text field is pre-filled with the current URL. Enter your stream URL (`https://host/live.m3u8` or `http://host/live.flv`) and tap **保存并启用**.

Controls available from the panel:

| Control | Behavior |
|---|---|
| 保存并启用 | save URL, enable replacement, (re)start the stream; empty URL shows a hint instead of starting |
| 停用 | stop replacement and restore the real camera feed (enabled=NO, persisted) |
| 刷新直播源 | stop → clear frame queue → re-read URL → restart the stream (manual reconnect) |
| 画面设置 | 镜像 / 旋转 / 比例 sub-panel |
| 取消 | dismiss |

Panel behavior:

- Shows current state from persisted settings: `● 已启用 / ○ 已停用 / ○ 未配置`, stream URL, 画面 (Fill/Fit/Stretch), 镜像, 旋转.
- `CBV2.AutoStart` (default YES): when YES and enabled and a URL is set, the stream starts automatically on plugin load; when NO the stream is not auto-started but the panel still appears.

Settings are persisted via `NSUserDefaults`:

- `CBV2.StreamURL`
- `CBV2.Enabled`
- `CBV2.Mirror`
- `CBV2.Rotation`
- `CBV2.AspectMode` (0=Fill, 1=Fit, 2=Stretch)
- `CBV2.AutoStart` (default YES)

## Stream notes

- HTTP-FLV supports AVC/H.264 video tags; audio tags are safely skipped (v1).
- Parser is state-machine based: a tag may span many network chunks; incomplete tags wait for more data; parsed bytes are compacted out.
- On disconnect / bad HTTP status the source reconnects with exponential backoff (2 s → 15 s cap).
- Plain `http://` may be blocked by the host app's ATS; prefer HTTPS when possible.

## Compatibility & diagnostics

Only the public `AVCaptureVideoDataOutput` delegate path is hooked. If the target app does not use that path, enable the built-in diagnostics (`[CBV2] AVCaptureSession startRunning`, `[CBV2] AVCaptureVideoDataOutput created`) and trace the real capture node before adding any compatibility layer. Do not guess private class names.

## License / scope

Independent implementation. No third-party plugin code, keys, or license bypasses are used.
