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

    // Create a tiny valid JPEG
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
