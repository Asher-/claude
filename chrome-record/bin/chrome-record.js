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
