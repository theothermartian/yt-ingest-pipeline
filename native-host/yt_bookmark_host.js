#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { execFile } = require("child_process");

// PIPELINE_DIR = parent of native-host/ (i.e. the project root)
const PIPELINE_DIR = path.resolve(__dirname, "..");
const BOOKMARK_FILE = path.join(PIPELINE_DIR, "bookmarks.txt");
const HOOK_SCRIPT = path.join(PIPELINE_DIR, "on_bookmark.sh");
const DEBUG_LOG = path.join(PIPELINE_DIR, "host_debug.log");

function dlog(msg) {
  try {
    fs.appendFileSync(DEBUG_LOG, `${new Date().toISOString()} ${msg}\n`);
  } catch (_) {}
}

function readMessage() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let totalLen = 0;
    let headerRead = false;
    let msgLen = 0;

    process.stdin.on("readable", () => {
      let chunk;
      while (null !== (chunk = process.stdin.read())) {
        chunks.push(chunk);
        totalLen += chunk.length;

        if (!headerRead && totalLen >= 4) {
          const buf = Buffer.concat(chunks);
          msgLen = buf.readUInt32LE(0);
          headerRead = true;
        }

        if (headerRead && totalLen >= 4 + msgLen) {
          const buf = Buffer.concat(chunks);
          const json = buf.slice(4, 4 + msgLen).toString("utf8");
          resolve(JSON.parse(json));
          return;
        }
      }
    });

    process.stdin.on("error", reject);
    process.stdin.on("end", () => reject(new Error("stdin closed")));
  });
}

function sendMessage(obj) {
  const json = JSON.stringify(obj);
  const buf = Buffer.alloc(4 + Buffer.byteLength(json));
  buf.writeUInt32LE(Buffer.byteLength(json), 0);
  buf.write(json, 4);
  process.stdout.write(buf);
}

function appendBookmark(entry) {
  const url = (entry.url || "").trim();
  const title = (entry.title || "").trim();
  const timestamp = entry.timestamp || new Date().toISOString();

  if (!url) throw new Error("Empty URL");

  fs.mkdirSync(PIPELINE_DIR, { recursive: true });
  fs.appendFileSync(BOOKMARK_FILE, `${timestamp}\t${url}\t${title}\n`);
  return { url, title, timestamp };
}

function runHook(url, title, timestamp) {
  if (!fs.existsSync(HOOK_SCRIPT)) return;
  const env = { ...process.env, YT_URL: url, YT_TITLE: title, YT_TIMESTAMP: timestamp };
  execFile("/bin/bash", [HOOK_SCRIPT, url], { env, detached: true, stdio: "ignore" }).unref();
}

async function main() {
  dlog("host started (node)");
  try {
    const entry = await readMessage();
    dlog(`received: ${JSON.stringify(entry)}`);
    const { url, title, timestamp } = appendBookmark(entry);
    runHook(url, title, timestamp);
    dlog(`saved ok: ${url}`);
    sendMessage({ ok: true, url });
  } catch (err) {
    dlog(`error: ${err.stack || err}`);
    sendMessage({ ok: false, error: String(err) });
  }
  process.exit(0);
}

main();
