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
