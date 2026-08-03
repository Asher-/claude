import { spawn, execSync } from "node:child_process";

export function checkFfmpeg() {
  try {
    execSync("ffmpeg -version", { stdio: "ignore" });
  } catch {
    throw new Error("ffmpeg not found. Install it: brew install ffmpeg");
  }
}

export function createEncoder({
  output,
  fps = 10,
  width = 1280,
  height = 720,
}) {
  const args = [
    "-y", // overwrite output
    "-f",
    "image2pipe", // input is piped images
    "-vcodec",
    "mjpeg", // input codec is JPEG
    "-framerate",
    String(fps), // input frame rate
    "-i",
    "-", // read from stdin
    "-c:v",
    "libx264", // H.264 output codec
    "-pix_fmt",
    "yuv420p", // compatibility
    "-preset",
    "fast", // encoding speed
    "-movflags",
    "+faststart", // web-friendly MP4
    output,
  ];

  const proc = spawn("ffmpeg", args, {
    stdio: ["pipe", "ignore", "pipe"],
  });

  let stderrBuf = "";
  proc.stderr.on("data", (chunk) => {
    stderrBuf += chunk.toString();
  });

  return {
    writeFrame(jpegBuffer) {
      if (!proc.stdin.destroyed) {
        proc.stdin.write(jpegBuffer);
      }
    },

    finalize() {
      return new Promise((resolve, reject) => {
        proc.on("close", (code) => {
          if (code === 0) resolve();
          else
            reject(
              new Error(
                `ffmpeg exited with code ${code}: ${stderrBuf.slice(-500)}`,
              ),
            );
        });
        proc.on("error", reject);
        proc.stdin.end();
      });
    },

    kill() {
      proc.kill("SIGTERM");
    },
  };
}
