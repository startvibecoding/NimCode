#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const https = require("https");

const pkg = require("./package.json");
const binDir = path.join(__dirname, "bin");

function platform() {
  switch (process.platform) {
    case "darwin": return "macos";
    case "win32": return "windows";
    case "linux": return "linux";
    default: return process.platform;
  }
}

function arch() {
  switch (process.arch) {
    case "x64": return "amd64";
    case "arm64": return "arm64";
    case "arm": return "arm";
    case "loong64": return "loongarch64";
    default: return process.arch;
  }
}

function binaryName() {
  const ext = process.platform === "win32" ? ".exe" : "";
  return `nimcode-${platform()}-${arch()}${ext}`;
}

function localBinaryPath() {
  return path.join(binDir, process.platform === "win32" ? "nimcode.exe" : "nimcode");
}

function findBundledBinary() {
  const name = binaryName();
  const bundled = path.join(__dirname, "bin", name);
  if (fs.existsSync(bundled)) return bundled;

  // Fallback: if package was bundled with multiple binaries, find a matching one
  if (fs.existsSync(binDir)) {
    const candidates = fs.readdirSync(binDir).filter((f) => f.startsWith("nimcode-"));
    for (const c of candidates) {
      const p = path.join(binDir, c);
      const stats = fs.statSync(p);
      if (stats.isFile() && !stats.isDirectory()) return p;
    }
  }
  return null;
}

function downloadBinary(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest, { mode: 0o755 });
    https
      .get(url, { timeout: 120000 }, (res) => {
        if (res.statusCode === 302 || res.statusCode === 301) {
          return downloadBinary(res.headers.location, dest).then(resolve).catch(reject);
        }
        if (res.statusCode !== 200) {
          return reject(new Error(`Download failed: ${res.statusCode} ${url}`));
        }
        res.pipe(file);
        file.on("finish", () => {
          file.close();
          resolve();
        });
      })
      .on("error", reject);
  });
}

async function main() {
  const bundled = findBundledBinary();
  if (bundled) {
    // Rename/move bundled binary to the canonical bin/nimcode path
    fs.mkdirSync(binDir, { recursive: true });
    const target = localBinaryPath();
    try {
      fs.copyFileSync(bundled, target);
      fs.chmodSync(target, 0o755);
      console.log(`Installed NimCode from bundled binary: ${path.basename(bundled)}`);
    } catch (e) {
      console.error("Failed to install bundled binary:", e.message);
      process.exit(1);
    }
    return;
  }

  // No bundled binary; try to download from GitHub release
  const version = pkg.version;
  const name = binaryName();
  const url = `https://github.com/nimcode/nimcode/releases/download/v${version}/${name}`;
  fs.mkdirSync(binDir, { recursive: true });
  const dest = localBinaryPath();

  console.log(`Downloading NimCode ${version} for ${platform()}-${arch()}...`);
  try {
    await downloadBinary(url, dest);
    console.log("NimCode installed successfully.");
  } catch (e) {
    console.error("Failed to download NimCode:", e.message);
    console.error("URL:", url);
    console.error("You can build from source or download manually from the releases page.");
    process.exit(1);
  }
}

main();
