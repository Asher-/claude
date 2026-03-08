// test/integration.test.js
import { describe, it, after } from "node:test";
import assert from "node:assert/strict";
import { execSync, spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";

const tmpOut = path.join(os.tmpdir(), `chrome-record-int-${Date.now()}.mp4`);
const binPath = path.join(import.meta.dirname, "..", "bin", "chrome-record.js");

describe("integration", () => {
  after(() => {
    if (fs.existsSync(tmpOut)) fs.unlinkSync(tmpOut);
    // Clean up any leftover session
    const sessionPath = path.join(
      os.homedir(),
      ".chrome-record",
      "session.json",
    );
    if (fs.existsSync(sessionPath)) fs.unlinkSync(sessionPath);
  });

  it("records a URL to MP4 and produces a valid file", async () => {
    // Start recording in background
    const proc = spawn(
      "node",
      [
        binPath,
        "start",
        "--url",
        "data:text/html,<h1>Hello</h1>",
        "-o",
        tmpOut,
        "--fps",
        "5",
        "--width",
        "320",
        "--height",
        "240",
      ],
      {
        stdio: "pipe",
      },
    );

    // Wait for recording to start
    await new Promise((resolve) => {
      proc.stdout.on("data", (data) => {
        if (data.toString().includes("Recording to")) resolve();
      });
      // Timeout fallback
      setTimeout(resolve, 10000);
    });

    // Let it record for 2 seconds
    await new Promise((r) => setTimeout(r, 2000));

    // Send SIGTERM to stop
    proc.kill("SIGTERM");

    // Wait for process to exit
    await new Promise((resolve) => {
      proc.on("close", resolve);
      setTimeout(resolve, 10000);
    });

    // Verify output
    assert.ok(fs.existsSync(tmpOut), "MP4 file should exist");
    const stat = fs.statSync(tmpOut);
    assert.ok(
      stat.size > 100,
      `MP4 file should have content (got ${stat.size} bytes)`,
    );

    // Verify it's a valid MP4 with ffprobe
    const probe = execSync(
      `ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 ${tmpOut}`,
    )
      .toString()
      .trim();
    assert.ok(probe.includes("h264"), `Should be H.264 codec, got: ${probe}`);
  });
});
