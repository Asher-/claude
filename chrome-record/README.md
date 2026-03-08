# chrome-record

Record Chrome browser activity to MP4 via CDP screencast. Runs headless or attaches to an existing Chrome instance with remote debugging enabled.

## Prerequisites

- Node.js (v18+)
- ffmpeg
- Chrome / Chromium (for headless mode, bundled via puppeteer-core is not included -- system Chrome is used)

## Install

```bash
cd chrome-record
npm install
npm link
```

## Usage

### Headless mode (launches Chrome)

```bash
chrome-record start --url https://example.com -o output.mp4
```

### Attach mode (connect to running Chrome)

Start Chrome with remote debugging:

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=9222
```

Then record:

```bash
chrome-record start --attach 9222 -o output.mp4
```

### Stop recording

```bash
chrome-record stop
```

## Options

| Option         | Description                                 | Default |
| -------------- | ------------------------------------------- | ------- |
| `-o, --output` | Output file path (required)                 |         |
| `--url`        | URL to open in headless Chrome              |         |
| `--attach`     | Port of a running Chrome debugging instance |         |
| `--fps`        | Frame rate                                  |      10 |
| `--width`      | Viewport width                              |    1280 |
| `--height`     | Viewport height                             |     800 |
| `--quality`    | JPEG quality (0-100)                        |      80 |

Either `--url` or `--attach` must be provided.
