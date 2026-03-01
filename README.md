# radio-scrobbler

**Auto-scrobble whatever's playing on your Mac.**

---

Listens to system audio via ScreenCaptureKit, fingerprints it with Shazam, and scrobbles to Last.fm. No browser extensions, no manual input — just leave it running.

## How It Works

System audio is continuously captured and fed through two parallel paths: a spectral analyzer watching for track changes, and a ring buffer accumulating audio for recognition. When the analyzer detects a transition (or a periodic timer fires), the buffered audio is written to a temp WAV and identified via [shazamio](https://github.com/dotX12/shazamio).

```
ScreenCaptureKit (system audio)
    │
    │  PCM 44.1kHz mono
    ├──────────────────────────────┐
    ▼                              ▼
AudioAnalyzer                  MusicRecognizer
├ FFT spectral flux               ├ 5-10s ring buffer
├ MFCC cosine distance            ├ WAV → recognize.py
└ transition detection ──trigger──→└ shazamio fingerprint
                                       │
                                       ▼
                               ScrobbleController
                               ├ now playing → Last.fm
                               ├ 30s eligibility gate
                               └ scrobble + offline queue
```

## Prerequisites

- macOS 14+
- Swift 6.0+
- [uv](https://github.com/astral-sh/uv) (Python package runner)
- Screen Recording permission (for system audio capture)
- Last.fm account

## Getting Started

```bash
git clone <repo>
cd anyradio-scrobbler
swift build
```

### Authenticate

```bash
radio-scrobbler login
```

### Start Scrobbling

```bash
radio-scrobbler start
```

### Debug Mode

```bash
radio-scrobbler start --debug
```

Surfaces the full pipeline state: audio buffer reception, spectral analysis metrics, recognition attempts, and scrobble decisions.

## Project Structure

```
Sources/
├── main.swift               # CLI entry point
├── Config.swift             # Session, lock file, paths
├── AudioCapture.swift       # ScreenCaptureKit stream
├── AudioAnalyzer.swift      # FFT + MFCC transition detection
├── MusicRecognizer.swift    # Audio → shazamio bridge
├── TrackSession.swift       # Play eligibility tracking
├── ScrobbleController.swift # Orchestrator + timers
├── ScrobbleQueue.swift      # Offline retry queue
└── LastFmClient.swift       # Last.fm API client

recognize.py                 # shazamio fingerprinting script
```

## Tech Stack

| Layer       | Technology       |
| ----------- | ---------------- |
| Language    | Swift 6          |
| Audio       | ScreenCaptureKit |
| DSP         | Accelerate/vDSP  |
| Recognition | shazamio (Python)|
| Runner      | uv               |
| API         | Last.fm          |

## How Recognition Triggers

| Trigger    | Interval | Purpose                          |
| ---------- | -------- | -------------------------------- |
| Transition | On event | Spectral flux + MFCC spike       |
| Periodic   | 50s      | Catch missed transitions         |
| Silence    | ~68s     | Clean exit when nothing's playing|

## License

MIT
