# CameraBridge V2 — Architecture

## Data flow

```text
                         ┌─────────────────────────────┐
 URL                     │  CBHTTPFLVSource            │
  ├─ .m3u8 ─────────────►│  HLS: AVPlayer ->           │
  │                      │  AVPlayerItemVideoOutput    │
  └─ .flv ──────────────►│  FLV: NSURLSession ->       │
                         │  FLV parser ->              │
                         │  AVC config (SPS/PPS) ->    │
                         │  CBH264Decoder (VT)         │
                         └──────────────┬──────────────┘
                                        │ CVPixelBuffer
                                        v
                                  CBFrameQueue
                          (bounded 3, latest wins, lock-protected)
                                        │
AVCaptureVideoDataOutput ──► CBCameraProxy ──► CBStreamManager
                                        │       │
                                        │       ├─ Core Image render
                                        │       │   (Fill/Fit/Stretch + Mirror + Rotation)
                                        │       │
                                        │       v
                                        │  CBSampleBufferFactory
                                        │  (new CMSampleBuffer, original timing)
                                        │       │
                                        v       v
                                   original delegate
```

## Threading model

| Thread / queue | Work |
|---|---|
| NSURLSession delegate queue (background) | FLV receive → parse → feed decoder |
| VideoToolbox internal | async decode → latest frame cache |
| `CBFrameQueue` serial lock queue | push/pop latest frame (never blocks on network) |
| AVCaptureVideoDataOutput delegate queue | pop latest → CI render → build CMSampleBuffer → forward to original delegate |

The camera callback never waits on the network: it always pops the newest ready frame and returns immediately.

## HTTP-FLV parser state machine

```text
WAIT_HEADER ──► READ_PREV_TAG_SIZE ──► READ_TAG_HEADER ──► READ_TAG_PAYLOAD ──► PROCESS_TAG ─┐
     ▲                                                                                        │
     └───────────────────────────────────────────────────────────────────────────────────────┘
```

- Bytes accumulate in one buffer; `cursor` only advances past complete structures.
- An incomplete tag (payload not fully arrived) simply waits for the next network chunk.
- Parsed bytes are compacted out when `cursor > 1 MB` or `cursor` is over half the buffer.
- Hard cap: 48 MB buffer → reconnect on overflow.

### FLV → AVC mapping

```text
FLV Tag (type 9)
 ├─ FrameType(4b) | CodecID(4b)           (7 = AVC/H.264)
 ├─ AVCPacketType                         (0 = seq header, 1 = NALU, 2 = end)
 ├─ CompositionTime (24b signed)
 └─ payload
     ├─ AVCDecoderConfigurationRecord     -> configurationVersion, SPS, PPS,
     │                                      lengthSizeMinusOne (+1) -> nalLengthSize
     └─ NALU(s)                           -> [lengthSize bytes length][NALU]...
```

### H.264 → VideoToolbox

- SPS/PPS NALUs build `CMVideoFormatDescriptionCreateFromH264ParameterSets` with the stream's `nalUnitHeaderLength` (default 4).
- Frame NALUs are framed AVCC-style (length prefix) into an **owned** `CMBlockBuffer` (data copied — safe for async decode).
- `VTDecompressionSessionDecodeFrame` with `kVTDecodeFrame_EnableAsynchronousDecompression`.
- New SPS/PPS → decoder reset + session rebuild; decode errors → reset; app teardown → `VTDecompressionSessionInvalidate`.

## Camera hook (public API only)

`AVCaptureVideoDataOutput -setSampleBufferDelegate:queue:` is hooked. The original delegate is wrapped in `CBCameraProxy`:

- Proxy forwards `captureOutput:didOutputSampleBuffer:fromConnection:` and the drop variant.
- `respondsToSelector:` / `methodSignatureForSelector:` / `forwardInvocation:` / `conformsToProtocol:` keep other delegate messages working.
- Replacement is a pure pass-through while `CBV2.Enabled == NO`.
- The output buffer format is never assumed: `CVPixelBufferGetPixelFormatType()` of the target camera buffer is read and the render target is created with that exact format (`32BGRA` / `420YpCbCr8BiPlanarVideoRange` / `...FullRange`). Core Image handles the conversion (no per-pixel CPU copies).

## Settings

| Key | Meaning | Default |
|---|---|---|
| `CBV2.StreamURL` | HLS or HTTP-FLV URL | empty |
| `CBV2.Enabled` | replacement on/off | YES |
| `CBV2.Mirror` | horizontal mirror | NO |
| `CBV2.Rotation` | 0/90/180/270 | 0 |
| `CBV2.AspectMode` | 0=Fill, 1=Fit, 2=Stretch | 0 |

Loaded at startup, saved on every change, invalid URLs are ignored (no crash).

## Log contract

Important milestones are logged once (not per frame):

```text
[CBV2] injected
[CBV2] camera delegate hooked
[CBV2] stream starting
[CBV2] HLS started / HTTP-FLV connected
[CBV2] FLV header parsed
[CBV2] AVC config parsed / SPS received / PPS received
[CBV2] H264 decoder ready
[CBV2] stream stopped / decoder reset / error ...
[CBV2] source=flv fps=29.8 decoded=30 injected=30     (1 s cadence)
```

## Reconnect & recovery

- HTTP-FLV: non-200 response, EOF, transport error, or buffer overflow → exponential backoff reconnect (2 s, 4 s, 8 s, cap 15 s); parser + decoder state reset before each attempt.
- HLS: `AVPlayerItemStatusFailed`, `AVPlayerItemFailedToPlayToEndTimeNotification`, `AVPlayerItemPlaybackStalledNotification` → player/item rebuild with the same backoff; display link keeps polling.
- Manual 停用 / URL change always tears down the source and clears the queue/caches.

## Known scope

- v1 hooks only the public `AVCaptureVideoDataOutput` delegate path; audio in FLV is skipped by design.
- If the target app uses a private capture graph, run diagnostics first (`[CBV2] AVCaptureSession startRunning`, `[CBV2] AVCaptureVideoDataOutput created`) and add a compatibility layer only after the real node is identified — no speculative private API hooks.
