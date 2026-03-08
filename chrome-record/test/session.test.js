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
