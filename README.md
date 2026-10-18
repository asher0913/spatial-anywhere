# Spatial Anywhere

[![CI](https://github.com/asher0913/spatial-anywhere/actions/workflows/ci.yml/badge.svg)](https://github.com/asher0913/spatial-anywhere/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Spatial Anywhere is a macOS menu-bar app that gives AirPods Spatial Audio (Spatialize Stereo, Fixed or Head Tracked) to apps that macOS leaves out: Spotify, Chrome, Edge, Firefox and other players that render audio with their own engines.

```text
selected apps ─► Core Audio process tap ─► private aggregate device ─► lock-free Float32 ring
   (muted while tapped)                                                          │
AirPods ◄── Bluetooth AAC-ELD ◄── macOS ◄── AVSampleBufferAudioRenderer ◄────────┘
                                             (spatialization allowed for stereo)
```

## Why apps miss out on Spatial Audio

macOS offers Spatialize Stereo only to audio that reaches it through Apple's playback APIs and is marked spatializable. Players that write PCM straight to Core Audio never are. The system log shows the difference: with Spotify playing directly, `coreaudiod` reports `mSpatializeStereoCCIsAvailable = NO`. With the same audio relayed, it reports the relay's stream as `Is Spatializable = 1` and the Sound menu offers Fixed and Head Tracked.

The relay captures the selected apps with a Core Audio process tap, mutes their direct output while tapped, and plays the captured Float32 PCM through `AVSampleBufferAudioRenderer` with `allowedAudioSpatializationFormats = .monoAndStereo`. The relay's own code only copies samples. It adds no encoding, resampling, gain or EQ.

## What it adds to Spatial Relay

This project started from [Spatial Relay](https://github.com/shevlfs/spatial-relay), which relays Spotify only. Spatial Anywhere adds:

- **Any app.** Choose any number of sources: presets for common players (Spotify, Chrome, Edge, Brave, Arc, Firefox, VLC, NetEase Cloud Music, QQ Music, TIDAL, Amazon Music) plus any other app that is playing right now. The selection is saved.
- **Helper processes.** Browsers and Electron apps play audio from helpers (`com.google.Chrome.helper`, Firefox's `plugin-container`). Each Core Audio process is resolved to the outermost `.app` bundle that contains it, so helpers count as their app.
- **Taps that follow apps.** On macOS 26 and later the tap follows bundle IDs with process restore, so a helper that starts later or an app that restarts is captured without user action. On earlier releases the tap is rebuilt when a selected app opens a new audio process. Changing the selection while relaying rebuilds the pipeline in about 0.15 s.
- **No double spatialization.** Apps that already provide Spatial Audio (Music, TV, Podcasts, QuickTime Player, Safari, IINA, Infuse) are never offered.
- **Diagnostics.** Start, tap format, rebuilds and failures are logged under the `com.asher0913.SpatialAnywhere` subsystem, and an error stays visible after the panel is reopened.
- **A measurement harness.** [`Tools/TapCompare`](Tools/TapCompare) records a source app and the relay at the same time and compares them sample by sample.

## Measured results

One Mac, macOS 27.0.1, AirPods Pro 3 (firmware 9A348), October 2026. Each source played a 16-bit/44.1 kHz track; `tapcompare` recorded 15 to 30 s of the source's own output and of the relay, and `compare.py` aligned them.

| Source | Spatial Audio | Level change | Correlation | SNR (relay vs source) | 10–19.5 kHz | 21–22.5 kHz | Relay delay |
|---|---|---|---|---|---|---|---|
| Chrome | Off | 0.00 dB | 1.00000 | 84.8 dB | 0.00 dB | −1.8 dB | 231 ms |
| Firefox | Off | 0.00 dB | 1.00000 | 84.1 dB | 0.00 dB | −2.0 dB | 170 ms |
| Chrome | Spatialize Stereo, Fixed | +4.1 dB | 0.49 | (rendered) | +5.1 dB | — | 416 ms |

What the numbers mean:

- **Capture is bit-exact.** A second tap configured like the relay's (drift compensation on) matched an independent tap on 100% of samples.
- **The renderer is not.** With Spatial Audio off, the output is flat to 19.5 kHz (in a Spotify run the residual sat 106 to 142 dB below the signal) and rolls off above 20 kHz (−0.6 dB at 20.5–21 kHz, −6.4 dB at 21.5–22 kHz). That is the signature of a resampling filter inside `AVSampleBufferAudioRenderer`, not of the relay code.
- **Bluetooth erases the difference.** The AirPods link stayed AAC-ELD at 256 kbps in every run, per `bluetoothd`'s link reports. AAC-ELD already drops content above about 20 kHz. When a Spotify recording and its relayed copy were both encoded with Apple's AAC-ELD 256 encoder, the two results differed by 43.1 dB SNR. The same source with −120 dBFS noise added differed by 40.7 dB. The codec's own error was 27.8 dB.
- **Spatialize Stereo is applied inside the relay's process.** With it on, the relay output is louder and the channels are mixed (correlation 0.5): the binaural render happens before the audio reaches Core Audio.

## Requirements

- Apple silicon Mac
- macOS 14.2 or later (bundle-ID taps need macOS 26)
- AirPods or Beats with Spatial Audio
- Xcode 26 or later to build

## Build and install

```sh
Scripts/package-release.sh 1.0.0
```

This builds an ad-hoc signed Release app and writes `build/SpatialAnywhere-1.0.0-arm64.zip`. Unzip it and move **Spatial Anywhere.app** to Applications. The app is not notarized, so the first launch needs Control-click → Open. You can also open `SpatialAnywhere.xcodeproj`, choose your Development Team and run the **SpatialAnywhere** scheme.

## Use

1. Connect your AirPods and choose them as the Mac's output.
2. Open Spatial Anywhere from the waveform icon in the menu bar.
3. Tick the apps to relay. Apps that are playing show **Playing**.
4. Click **Start relay** and allow **System Audio Recording** when macOS asks.
5. In the Sound or AirPods menu, choose **Fixed** or **Head Tracked** under Spatial Audio.

Stop the relay before switching output devices. **Quit Spatial Anywhere** in the ellipsis menu restores every app's direct output.

## Verify it yourself

```sh
swiftc -O Tools/TapCompare/main.swift -o build/tapcompare
build/tapcompare 20 build/run com.google.Chrome   # relay running, Chrome playing, Spatial Audio off
python3 Tools/TapCompare/compare.py build/run      # needs numpy and scipy
```

## Audio and privacy

Captured audio lives in a bounded in-memory ring. It is never written to disk or sent anywhere. The app is sandboxed without network access. Selected apps are muted only while their tap exists; stop, quit and failure paths remove the tap and restore direct output.

## Limitations

- Not bit-perfect: the system renderer low-passes above 20 kHz. The Bluetooth codec removes that band anyway.
- The relay adds 0.2 to 0.5 s of delay, so browser video can look out of sync.
- Audio is relayed as a stereo mixdown.
- Changing the selection while relaying causes a gap of about 0.15 s.
- Before macOS 26, an app has to be playing before the relay can start.
- Tested on hardware: Chrome and Firefox, plus Spotify through the upstream app, which uses the same capture and render pipeline. The other presets are untested.

## Credits

Built on [Spatial Relay](https://github.com/shevlfs/spatial-relay) by shevlfs (MIT License). The capture ring buffer, renderer timeline recovery and teardown order come from that project.

## License

MIT. See [LICENSE](LICENSE).

Spotify, AirPods, Spatial Audio, macOS and the other product names are trademarks of their owners. This project is independent and not affiliated with or endorsed by any of them.
