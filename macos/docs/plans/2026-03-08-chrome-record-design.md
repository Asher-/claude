# chrome-record: Offscreen Chrome Recording CLI

**Date:** 2026-03-08
**Status:** Approved

## Purpose

A CLI tool that records Chrome browser activity to MP4 without requiring the window to be visible on screen. Primary use case: recording Claude Code browser automation (via Chrome MCP tools) so the user can keep working while automation runs.

## Architecture

```
+----------------+    CDP/WebSocket    +----------------+
| chrome-record  |<------------------->|     Chrome      |
|   (Node.js)    |  screencastFrame    | (headless or    |
|                |  events (base64 jpg)|  existing)      |
+-------+--------+                     +----------------+
        | stdin pipe (raw frames)
        v
+----------------+
|     ffmpeg     |---> output.mp4
+----------------+
```

## CLI Interface

```bash
# Launch headless Chrome, navigate to URL, record
chrome-record start --url https://example.com -o recording.mp4

# Attach to existing Chrome (remote debugging port)
chrome-record start --attach 9222 -o recording.mp4

# Stop recording (writes MP4)
chrome-record stop
```

### Options

| Flag        | Default | Description                    |
| ----------- | ------- | ------------------------------ |
| `--fps`     | 10      | Frame rate                     |
| `--width`   | 1280    | Viewport width                 |
| `--height`  | 800     | Viewport height                |
| `--quality` | 80      | JPEG quality 0-100             |
| `--format`  | mp4     | Output format (mp4 for now)    |
| `-o`        | -       | Output file path (required)    |
| `--url`     | -       | URL to navigate to (launch mode) |
| `--attach`  | -       | Remote debugging port (attach mode) |

## How It Works

1. **Start:** Launches headless Chrome (or connects to existing instance via `--attach PORT`). Writes session state to `~/.chrome-record/session.json`.
2. **Frame capture:** CDP `Page.startScreencast` streams JPEG frames. Each frame is acknowledged via `Page.screencastFrameAck` to maintain flow control.
3. **Encoding:** Frames are piped to an ffmpeg subprocess as raw images, encoded to H.264 MP4.
4. **Stop:** `chrome-record stop` sends SIGTERM to the recording process, which flushes ffmpeg and finalizes the MP4. Cleans up session file.

## State Management

```
~/.chrome-record/
  session.json    # { pid, outputPath, startTime, port, url }
```

`start` refuses if a session is already active. `stop` cleans up the session file.

## Dependencies

- `puppeteer-core` (avoids bundling Chromium; uses system Chrome or headless)
- `ffmpeg` (system dependency, checked at startup with clear error message)

## Project Location

`/Users/asher/Dropbox/Projects/claude/chrome-record/` - standalone Node.js package.

## Scope Boundaries (v1)

- No audio capture (CDP screencast is video-only)
- No mouse cursor overlay or click indicators
- No streaming/live preview - file output only
- No browser interaction - records only, Claude handles navigation via MCP
