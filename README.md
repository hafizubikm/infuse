# Reel

A personal, Mac-only video player in the spirit of Infuse. It plays MKV, MP4, MOV, M4V, AVI, TS/M2TS and WebM with Apple-native picture and sound: HDR10, HLG and Dolby Vision on the XDR display, plus Dolby Atmos and head-tracked Spatial Audio on AirPods. A binaural virtual-surround mode covers other headphones.

**How it works:** FFmpeg only *demuxes* the file. Compressed video packets become `CMSampleBuffer`s with the right format description (avcC/hvcC/av1C, plus dvcC/dvvC for Dolby Vision, plus HDR metadata), and `AVSampleBufferDisplayLayer` decodes them in hardware and tone-maps them. E-AC-3/AC-3/AAC go to `AVSampleBufferAudioRenderer` untouched, so macOS decodes Atmos and spatializes it. Everything else is decoded by FFmpeg and handed to the same renderers. `AVSampleBufferRenderSynchronizer` keeps audio and video in sync, with audio as the master clock.

## What plays how

| Content | Path |
| --- | --- |
| H.264, HEVC (8/10-bit), AV1 | Compressed samples → `AVSampleBufferDisplayLayer` (VideoToolbox hardware decode, EDR tone mapping) |
| HDR10 / HLG | Same, with colour primaries, transfer function, matrix, mastering display and MaxCLL/MaxFALL in the format description |
| Dolby Vision 5, 8.1, 8.4 | `dvh1` + `hvcC` + `dvcC`/`dvvC`: real Dolby Vision. If the renderer refuses, 8.x falls back to its HDR10/HLG base layer |
| Dolby Vision 7 (UHD Blu-ray) | Enhancement layer and RPU removed, HDR10 base layer played; shown as "Dolby Vision Profile 7 → playing HDR10 base layer" |
| AAC, AC-3, E-AC-3 (incl. Atmos JOC) | Passed compressed to `AVSampleBufferAudioRenderer`; macOS decodes and spatializes (head-tracked on AirPods) |
| TrueHD, DTS / DTS-HD MA, FLAC, Opus, Vorbis, MP3, PCM … | FFmpeg-decoded Float32 PCM with a Core Audio channel layout (5.1/7.1 …) → same audio renderer, so Spatial Audio still applies. TrueHD Atmos / DTS:X play their channel bed |
| Any 5.1/7.1 track in **Virtual Surround** | Decoded by FFmpeg (E-AC-3 too) → each channel placed on a virtual speaker (C 0°, L/R ±30°, Ls/Rs ±110°, Lrs/Rrs ±150°, LFE to both ears) → rendered for headphones with Apple's HRTF in an offline `AVAudioEngine` → stereo PCM to the same renderer, macOS spatialization off |
| Any 5.1/7.1 track in **Stereo** | Decoded by FFmpeg → ITU-style stereo downmix, no spatial processing |
| MPEG-2, VC-1, VP9, VP8, MPEG-4/Xvid, H.264 Hi10P … | FFmpeg decode (VideoToolbox-accelerated where available, e.g. VP9) → IOSurface NV12/P010 pixel buffers with colour/HDR attachments → same display layer. Also the automatic fallback if the hardware path rejects a stream |

| Subtitles: SRT, ASS/SSA, mov_text, WebVTT, PGS, VobSub, DVB | Decoded by FFmpeg (text → ASS events, bitmaps → RGBA) and drawn by Reel on an SDR overlay above the picture, so they stay white over HDR. Sidecar `Movie.srt` / `Movie.en.forced.ass` files load automatically. **S** cycles tracks; size and background in Settings (⌘,) |

Press **I** while playing to see the stream details and the path actually in use.

## Using Reel

- **Library:** add folders (⇧⌘O or the sidebar's *Add Folder…*); external drives are remembered and
  show greyed out while disconnected. Continue Watching and Recently Played come from your history.
- **Opening:** double-click in the library, drop files on any window or the Dock icon, ⌘O, or
  *Open With › Reel* / double-click in Finder.
- **Resume:** Reel resumes where you stopped (with the audio/subtitle tracks you picked); the banner
  offers *Start Over*.

| Key | Action |
| --- | --- |
| Space | Play / pause |
| ← / → | Back / forward 10 s (⇧ for 60 s) |
| ↑ / ↓ | Volume |
| F / Esc | Full screen / exit full screen |
| M | Mute |
| S / A | Next subtitle / audio track |
| I | Info overlay |

### Sound

Settings › Audio (⌘,) or the player's audio menu:

- **Auto** (default): AirPods, Beats and the Mac's speakers get Apple Spatial Audio (head-tracked on
  AirPods). Receivers, TVs and AirPlay get the multichannel signal. For other headphones — Bluetooth
  ones like the Sony WH-1000XM5, the headphone jack, USB headsets — Reel offers *Virtual Surround*
  the first time a surround track plays and remembers the answer per device.
- **Apple Spatial Audio**, **Virtual Surround**, **Stereo**: force one for every output.

Reel follows the output device live: connect AirPods mid-film and it switches back to Apple Spatial
Audio at the same position (a short re-buffer, no drift). The info overlay (**I**) shows the mode,
the device and the exact audio path.

Media keys, AirPods controls and Control Center work through Now Playing; the control bar also has
audio, subtitle and speed menus, Picture in Picture and full screen.

## Requirements

- Apple Silicon Mac, macOS 14 or later
- Xcode 16 or later, selected with `sudo xcode-select -s /Applications/Xcode.app`

## Build

```bash
scripts/build-ffmpeg.sh        # once: FFmpeg 7.1 → Vendor/FFmpeg/FFmpeg.xcframework (static, LGPL, arm64)
open Reel.xcodeproj            # then Run (⌘R)
```

To build a Release copy into `/Applications` and register it for "Open With" and double-click:

```bash
scripts/install.sh
```

`build-ffmpeg.sh` downloads the pinned FFmpeg release, checks its SHA-256, and configures it LGPL-only with VideoToolbox and no programs, encoders, muxers, network or devices. It then packages one static `libFFmpeg.a` and its headers as an xcframework. It needs only Xcode's toolchain; Homebrew is not used. Debug builds are unoptimised Swift, so use `scripts/install.sh` (Release) for big 4K remuxes.

## Tests

```bash
xcodebuild -project Reel.xcodeproj -scheme Reel -destination 'platform=macOS,arch=arm64' test
```

The tests use the tiny synthetic clips in `TestMedia/`: HDR10, HLG, Dolby Vision 5/8.1 (synthetic RPUs), AV1, VP9, TrueHD, DTS, FLAC 7.1, subtitles and so on. They are regenerated by `scripts/make-fixtures.sh`, which needs dev-only tools (full ffmpeg, mkvmerge, Rust). Tests that need hardware decoders skip themselves when none are available, as on CI. CI (`.github/workflows/build.yml`) builds and tests on an Apple Silicon runner and caches the FFmpeg build; it runs only when started by hand from the Actions tab.

## Layout

| Path | Purpose |
| --- | --- |
| `Reel/App` | App entry point, opening files, settings, logging |
| `Reel/Demuxer` | FFmpeg file access, stream probing (`MediaInfo`), packet reading |
| `Reel/VideoPipeline` | Format descriptions (HDR/Dolby Vision), compressed and decoded video feeding |
| `Reel/AudioPipeline` | Passthrough and PCM audio, channel layouts, output-device monitoring |
| `Reel/Virtualizer` | Binaural virtual surround (AVAudioEnvironmentNode HRTF) |
| `Reel/SubtitleRenderer` | Text and bitmap subtitles, overlay layer |
| `Reel/PlaybackController` | Playback engine, sync, seeking, Now Playing, track labels |
| `Reel/Library` | Folders, scanning, resume points, recents |
| `Reel/UI` | SwiftUI library and AppKit player views |
| `Modules/CFFmpeg` | Clang module exposing FFmpeg plus a small C shim to Swift |
| `Config` | xcconfig build settings and Info.plist (document types) |

The Xcode project uses folder-synchronized groups, so new files under `Reel/` and `ReelTests/` are picked up automatically.

## Known limits

- TrueHD Atmos and DTS:X play their 7.1/5.1 channel bed: no public decoder renders their objects.
  E-AC-3 Atmos goes to macOS untouched in Apple Spatial Audio mode; in Virtual Surround / Stereo
  Reel decodes its bed.
- Dolby Vision Profile 7 plays its HDR10 base layer; Profile 5 has no fallback if the Mac can't
  render it.
- AirPods and Beats are recognised by name or Apple's Bluetooth vendor ID. If a device is
  misjudged, pick the Sound mode by hand; the log shows how each output was classified.
- Subtitles aren't shown in Picture in Picture.

## Logs

```bash
log stream --predicate 'subsystem == "app.reel.player"' --level debug
```

Output-device changes are logged as `Output device: <name> [transport, manufacturer, model, channels] → kind`.

## License notes

Personal use. FFmpeg is linked statically in an LGPL v2.1+ configuration; its license is installed to `Vendor/FFmpeg/LICENSE.LGPLv2.1` at build time.
