import fs from 'node:fs';
import puppeteer from 'puppeteer-core';
import { checkFfmpeg, createEncoder } from './encoder.js';
import { saveSession, isSessionActive, clearSession } from './session.js';

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

export async function startRecording(opts) {
  checkFfmpeg();

  if (isSessionActive()) {
    console.error('A recording session is already active. Run "chrome-record stop" first.');
    process.exit(1);
  }

  const { output, url, attach, fps, width, height, quality } = opts;

  let browser, page;

  if (attach) {
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
    const chromePath = findChrome();
    if (!chromePath) {
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
