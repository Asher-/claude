# chrome-record Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a CLI tool that records Chrome browser activity to MP4 offscreen using CDP screencast + ffmpeg.

**Architecture:** Node.js CLI using puppeteer-core for CDP communication. `Page.startScreencast` streams JPEG frames which are decoded and piped to ffmpeg's stdin as raw image data. Two modes: launch headless Chrome, or attach to existing instance via remote debugging port. Session state persisted to `~/.chrome-record/session.json` for start/stop coordination.

**Tech Stack:** Node.js, puppeteer-core, ffmpeg (system), commander (CLI parsing)

---

### Task 1: Project Scaffold

**Files:**
- Create: `chrome-record/package.json`
- Create: `chrome-record/bin/chrome-record.js`
- Create: `chrome-record/.gitignore`

**Step 1: Create project directory**

```bash
mkdir -p /Users/asher/Dropbox/Projects/claude/chrome-record/bin
```

**Step 2: Create package.json**

```json
{
  "name": "chrome-record",
  "version": "0.1.0",
  "description": "Record Chrome browser activity to MP4 offscreen via CDP screencast",
  "type": "module",
  "bin": {
    "chrome-record": "./bin/chrome-record.js"
  },
  "scripts": {
    "test": "node --test test/"
  },
  "dependencies": {
    "commander": "^13.0.0",
    "puppeteer-core": "^24.0.0"
  }
}
```

**Step 3: Create .gitignore**

```
node_modules/
```

**Step 4: Create bin/chrome-record.js stub**

```javascript
#!/usr/bin/env node
import { program } from 'commander';

program
  .name('chrome-record')
  .description('Record Chrome browser activity to MP4 offscreen')
  .version('0.1.0');

program
  .command('start')
  .description('Start recording')
  .requiredOption('-o, --output <path>', 'Output file path')
  .option('--url <url>', 'URL to navigate to (launches headless Chrome)')
  .option('--attach <port>', 'Attach to existing Chrome on this debugging port', parseInt)
  .option('--fps <n>', 'Frame rate', parseInt, 10)
  .option('--width <n>', 'Viewport width', parseInt, 1280)
  .option('--height <n>', 'Viewport height', parseInt, 800)
  .option('--quality <n>', 'JPEG quality 0-100', parseInt, 80)
  .action(async (opts) => {
    const { startRecording } = await import('../lib/recorder.js');
    await startRecording(opts);
  });

program
  .command('stop')
  .description('Stop recording and finalize MP4')
  .action(async () => {
    const { stopRecording } = await import('../lib/session.js');
    await stopRecording();
  });

program.parse();
```

**Step 5: Install dependencies**

```bash
cd /Users/asher/Dropbox/Projects/claude/chrome-record
npm install
```

**Step 6: Make bin executable**

```bash
chmod +x bin/chrome-record.js
```

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: scaffold chrome-record project with CLI structure"
```

---

### Task 2: Session Management

**Files:**
- Create: `chrome-record/lib/session.js`
- Create: `chrome-record/test/session.test.js`

**Step 1: Write the failing test**

```javascript
// test/session.test.js
import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

// Use a temp dir instead of ~/.chrome-record for tests
const testDir = path.join(os.tmpdir(), 'chrome-record-test-' + Date.now());

describe('session', () => {
  before(() => fs.mkdirSync(testDir, { recursive: true }));
  after(() => fs.rmSync(testDir, { recursive: true, force: true }));

  it('saveSession writes session.json', async () => {
    const { saveSession, loadSession } = await import('../lib/session.js');
    const data = { pid: 12345, outputPath: '/tmp/out.mp4', startTime: Date.now() };
    saveSession(data, testDir);

    const loaded = loadSession(testDir);
    assert.equal(loaded.pid, 12345);
    assert.equal(loaded.outputPath, '/tmp/out.mp4');
  });

  it('clearSession removes session.json', async () => {
    const { saveSession, clearSession, loadSession } = await import('../lib/session.js');
    saveSession({ pid: 1 }, testDir);
    clearSession(testDir);
    assert.equal(loadSession(testDir), null);
  });

  it('isSessionActive returns true when session exists', async () => {
    const { saveSession, isSessionActive, clearSession } = await import('../lib/session.js');
    saveSession({ pid: 1 }, testDir);
    assert.equal(isSessionActive(testDir), true);
    clearSession(testDir);
    assert.equal(isSessionActive(testDir), false);
  });
});
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/asher/Dropbox/Projects/claude/chrome-record
node --test test/session.test.js
```

Expected: FAIL — module not found

**Step 3: Implement session.js**

```javascript
// lib/session.js
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const DEFAULT_DIR = path.join(os.homedir(), '.chrome-record');

function sessionPath(dir) {
  return path.join(dir || DEFAULT_DIR, 'session.json');
}

export function saveSession(data, dir) {
  const d = dir || DEFAULT_DIR;
  fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(sessionPath(d), JSON.stringify(data, null, 2));
}

export function loadSession(dir) {
  const p = sessionPath(dir);
  if (!fs.existsSync(p)) return null;
  return JSON.parse(fs.readFileSync(p, 'utf-8'));
}

export function clearSession(dir) {
  const p = sessionPath(dir);
  if (fs.existsSync(p)) fs.unlinkSync(p);
}

export function isSessionActive(dir) {
  return fs.existsSync(sessionPath(dir));
}

export async function stopRecording() {
  const session = loadSession();
  if (!session) {
    console.error('No active recording session.');
    process.exit(1);
  }

  try {
    process.kill(session.pid, 'SIGTERM');
    console.log(`Sent stop signal to recording process (PID ${session.pid}).`);
    console.log(`Output: ${session.outputPath}`);
  } catch (err) {
    if (err.code === 'ESRCH') {
      console.error(`Recording process (PID ${session.pid}) is not running.`);
    } else {
      throw err;
    }
  }

  clearSession();
}
```

**Step 4: Run test to verify it passes**

```bash
node --test test/session.test.js
```

Expected: PASS

**Step 5: Commit**

```bash
git add lib/session.js test/session.test.js
git commit -m "feat: add session management (save/load/clear)"
```

---

### Task 3: ffmpeg Spawning and Frame Piping

**Files:**
- Create: `chrome-record/lib/encoder.js`
- Create: `chrome-record/test/encoder.test.js`

**Step 1: Write the failing test**

```javascript
// test/encoder.test.js
import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const tmpOut = path.join(os.tmpdir(), `chrome-record-enc-test-${Date.now()}.mp4`);

describe('encoder', () => {
  after(() => {
    if (fs.existsSync(tmpOut)) fs.unlinkSync(tmpOut);
  });

  it('checkFfmpeg does not throw when ffmpeg is available', async () => {
    const { checkFfmpeg } = await import('../lib/encoder.js');
    assert.doesNotThrow(() => checkFfmpeg());
  });

  it('creates an MP4 file from piped JPEG frames', async () => {
    const { createEncoder } = await import('../lib/encoder.js');

    // Create a tiny valid JPEG (1x1 red pixel)
    // This is a minimal valid JPEG file
    const { execSync } = await import('node:child_process');
    const jpegPath = path.join(os.tmpdir(), 'test-frame.jpg');
    execSync(`ffmpeg -y -f lavfi -i color=c=red:s=64x48:d=0.1 -frames:v 1 ${jpegPath}`, { stdio: 'ignore' });
    const jpegData = fs.readFileSync(jpegPath);

    const encoder = createEncoder({
      output: tmpOut,
      fps: 5,
      width: 64,
      height: 48,
    });

    // Write the same frame 5 times (1 second of video)
    for (let i = 0; i < 5; i++) {
      encoder.writeFrame(jpegData);
    }

    await encoder.finalize();

    assert.ok(fs.existsSync(tmpOut), 'MP4 file should exist');
    const stat = fs.statSync(tmpOut);
    assert.ok(stat.size > 0, 'MP4 file should not be empty');

    fs.unlinkSync(jpegPath);
  });
});
```

**Step 2: Run test to verify it fails**

```bash
node --test test/encoder.test.js
```

Expected: FAIL — module not found

**Step 3: Implement encoder.js**

The encoder spawns ffmpeg, accepts JPEG frames as Buffers, decodes them via ffmpeg's `image2pipe` demuxer, and outputs H.264 MP4.

```javascript
// lib/encoder.js
import { spawn, execSync } from 'node:child_process';

export function checkFfmpeg() {
  try {
    execSync('ffmpeg -version', { stdio: 'ignore' });
  } catch {
    throw new Error('ffmpeg not found. Install it: brew install ffmpeg');
  }
}

export function createEncoder({ output, fps = 10, width = 1280, height = 48 }) {
  const args = [
    '-y',                          // overwrite output
    '-f', 'image2pipe',            // input is piped images
    '-framerate', String(fps),     // input frame rate
    '-i', '-',                     // read from stdin
    '-c:v', 'libx264',            // H.264 codec
    '-pix_fmt', 'yuv420p',        // compatibility
    '-preset', 'fast',             // encoding speed
    '-movflags', '+faststart',    // web-friendly MP4
    output,
  ];

  const proc = spawn('ffmpeg', args, {
    stdio: ['pipe', 'ignore', 'pipe'],
  });

  let stderrBuf = '';
  proc.stderr.on('data', (chunk) => { stderrBuf += chunk.toString(); });

  return {
    writeFrame(jpegBuffer) {
      if (!proc.stdin.destroyed) {
        proc.stdin.write(jpegBuffer);
      }
    },

    finalize() {
      return new Promise((resolve, reject) => {
        proc.on('close', (code) => {
          if (code === 0) resolve();
          else reject(new Error(`ffmpeg exited with code ${code}: ${stderrBuf.slice(-500)}`));
        });
        proc.on('error', reject);
        proc.stdin.end();
      });
    },

    kill() {
      proc.kill('SIGTERM');
    },
  };
}
```

**Step 4: Run test to verify it passes**

```bash
node --test test/encoder.test.js
```

Expected: PASS

**Step 5: Commit**

```bash
git add lib/encoder.js test/encoder.test.js
git commit -m "feat: add ffmpeg encoder for piping JPEG frames to MP4"
```

---

### Task 4: CDP Screencast Capture

**Files:**
- Create: `chrome-record/lib/recorder.js`

This is the core module. It connects to Chrome (headless or existing), starts CDP screencast, and pipes frames to the encoder. No unit test for this one — it requires a real browser. We'll integration-test in Task 5.

**Step 1: Implement recorder.js**

```javascript
// lib/recorder.js
import puppeteer from 'puppeteer-core';
import { checkFfmpeg, createEncoder } from './encoder.js';
import { saveSession, isSessionActive } from './session.js';

// Find Chrome on macOS
function findChrome() {
  const paths = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ];
  for (const p of paths) {
    try {
      const fs = await import('node:fs');
      if (fs.default.existsSync(p)) return p;
    } catch {}
  }
  return null;
}

export async function startRecording(opts) {
  checkFfmpeg();

  if (isSessionActive()) {
    console.error('A recording session is already active. Run "chrome-record stop" first.');
    process.exit(1);
  }

  const { output, url, attach, fps, width, height, quality } = opts;

  let browser, page;

  if (attach) {
    // Attach to existing Chrome instance
    browser = await puppeteer.connect({
      browserURL: `http://127.0.0.1:${attach}`,
    });
    const pages = await browser.pages();
    page = pages[0];
    if (!page) {
      console.error('No open tabs found in the attached browser.');
      process.exit(1);
    }
    console.log(`Attached to Chrome on port ${attach}`);
  } else {
    // Launch headless Chrome
    const chromePath = findChrome();
    if (!chromePath) {
      // Fall back: let puppeteer-core try to find it
      console.error('Chrome not found. Specify --attach or install Chrome.');
      process.exit(1);
    }

    browser = await puppeteer.launch({
      executablePath: chromePath,
      headless: true,
      args: [
        `--window-size=${width},${height}`,
      ],
    });
    page = await browser.newPage();
    await page.setViewport({ width, height });

    if (url) {
      console.log(`Navigating to ${url}`);
      await page.goto(url, { waitUntil: 'networkidle2' });
    }
    console.log('Launched headless Chrome');
  }

  // Start encoder
  const encoder = createEncoder({ output, fps, width, height });

  // Start CDP screencast
  const cdp = await page.createCDPSession();

  cdp.on('Page.screencastFrame', async (frame) => {
    const buf = Buffer.from(frame.data, 'base64');
    encoder.writeFrame(buf);
    // Acknowledge frame to keep the stream flowing
    await cdp.send('Page.screencastFrameAck', { sessionId: frame.sessionId });
  });

  await cdp.send('Page.startScreencast', {
    format: 'jpeg',
    quality,
    maxWidth: width,
    maxHeight: height,
    everyNthFrame: 1,
  });

  console.log(`Recording to ${output} at ${fps} fps...`);

  // Save session so "stop" can find us
  saveSession({
    pid: process.pid,
    outputPath: output,
    startTime: Date.now(),
  });

  // Handle graceful shutdown
  const shutdown = async () => {
    console.log('\nStopping recording...');
    try {
      await cdp.send('Page.stopScreencast');
    } catch {}
    await encoder.finalize();
    const { clearSession } = await import('./session.js');
    clearSession();
    if (!attach) {
      await browser.close();
    } else {
      browser.disconnect();
    }
    console.log(`Recording saved to ${output}`);
    process.exit(0);
  };

  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);

  // Keep process alive
  await new Promise(() => {});
}
```

**Step 2: Review for issues**

Read through the code and verify:
- `findChrome()` uses top-level await inside a regular function — fix by making it sync with `fs.existsSync` directly (no dynamic import needed, import fs at top).
- Shutdown handler properly stops screencast, finalizes encoder, and cleans up.

**Step 3: Fix the findChrome function**

Replace `findChrome` with a synchronous version:

```javascript
import fs from 'node:fs';

function findChrome() {
  const paths = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  ];
  for (const p of paths) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}
```

**Step 4: Commit**

```bash
git add lib/recorder.js
git commit -m "feat: add CDP screencast recorder with headless and attach modes"
```

---

### Task 5: Integration Test

**Files:**
- Create: `chrome-record/test/integration.test.js`

This test launches headless Chrome, records a few seconds, stops, and verifies the MP4 output.

**Step 1: Write the integration test**

```javascript
// test/integration.test.js
import { describe, it, after } from 'node:test';
import assert from 'node:assert/strict';
import { execSync, spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const tmpOut = path.join(os.tmpdir(), `chrome-record-int-${Date.now()}.mp4`);
const binPath = path.join(import.meta.dirname, '..', 'bin', 'chrome-record.js');

describe('integration', () => {
  after(() => {
    if (fs.existsSync(tmpOut)) fs.unlinkSync(tmpOut);
    // Clean up any leftover session
    const sessionPath = path.join(os.homedir(), '.chrome-record', 'session.json');
    if (fs.existsSync(sessionPath)) fs.unlinkSync(sessionPath);
  });

  it('records a URL to MP4 and produces a valid file', async () => {
    // Start recording in background
    const proc = spawn('node', [binPath, 'start', '--url', 'data:text/html,<h1>Hello</h1>', '-o', tmpOut, '--fps', '5', '--width', '320', '--height', '240'], {
      stdio: 'pipe',
    });

    // Wait for recording to start
    await new Promise((resolve) => {
      proc.stdout.on('data', (data) => {
        if (data.toString().includes('Recording to')) resolve();
      });
      // Timeout fallback
      setTimeout(resolve, 10000);
    });

    // Let it record for 2 seconds
    await new Promise((r) => setTimeout(r, 2000));

    // Send SIGTERM to stop
    proc.kill('SIGTERM');

    // Wait for process to exit
    await new Promise((resolve) => {
      proc.on('close', resolve);
      setTimeout(resolve, 10000);
    });

    // Verify output
    assert.ok(fs.existsSync(tmpOut), 'MP4 file should exist');
    const stat = fs.statSync(tmpOut);
    assert.ok(stat.size > 100, `MP4 file should have content (got ${stat.size} bytes)`);

    // Verify it's a valid MP4 with ffprobe
    const probe = execSync(`ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 ${tmpOut}`).toString().trim();
    assert.ok(probe.includes('h264'), `Should be H.264 codec, got: ${probe}`);
  });
});
```

**Step 2: Run the integration test**

```bash
node --test test/integration.test.js --timeout 30000
```

Expected: PASS — MP4 file is created, valid H.264

**Step 3: Commit**

```bash
git add test/integration.test.js
git commit -m "test: add integration test for end-to-end recording"
```

---

### Task 6: npm Link for Global CLI Access

**Step 1: Link the CLI globally**

```bash
cd /Users/asher/Dropbox/Projects/claude/chrome-record
npm link
```

**Step 2: Verify it works**

```bash
chrome-record --help
chrome-record start --url "data:text/html,<h1>Test</h1>" -o /tmp/test-recording.mp4 &
sleep 3
chrome-record stop
ffprobe /tmp/test-recording.mp4
```

**Step 3: Commit any fixes needed**

---

### Task 7: README

**Files:**
- Create: `chrome-record/README.md`

**Step 1: Write README**

Brief README covering: what it does, install (`npm link`), usage (start/stop with examples for both headless and attach modes), options table, prerequisites (ffmpeg, Chrome).

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with usage instructions"
```
