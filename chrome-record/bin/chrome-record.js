#!/usr/bin/env node
import { program } from "commander";

// Commander passes (value, previous) — raw parseInt would use previous as radix
const int = (v) => parseInt(v, 10);

program
  .name("chrome-record")
  .description("Record Chrome browser activity to MP4 offscreen")
  .version("0.1.0");

program
  .command("start")
  .description("Start recording")
  .requiredOption("-o, --output <path>", "Output file path")
  .option("--url <url>", "URL to navigate to (launches headless Chrome)")
  .option(
    "--attach <port>",
    "Attach to existing Chrome on this debugging port",
    int,
  )
  .option("--fps <n>", "Frame rate", int, 10)
  .option("--width <n>", "Viewport width", int, 1280)
  .option("--height <n>", "Viewport height", int, 800)
  .option("--quality <n>", "JPEG quality 0-100", int, 80)
  .action(async (opts) => {
    const { startRecording } = await import("../lib/recorder.js");
    await startRecording(opts);
  });

program
  .command("stop")
  .description("Stop recording and finalize MP4")
  .action(async () => {
    const { stopRecording } = await import("../lib/session.js");
    await stopRecording();
  });

program.parse();
