#!/usr/bin/env node
// ═════════════════════════════════════════════════════════════════════════════
// Experiment 17 — the other half of the stopwatch.
//
// Stands in for the daemon: writes cache/mfa.json the way the real one will
// (temp file + rename, never a partial file visible at the path), 20 times with
// randomized 1-3 s gaps, then unlinks it. Each file carries the wall-clock
// instant the write began; the app stamps the instant the icon finished
// changing. Subtracting is the whole experiment.
//
//   node writer.mjs                 all three techniques, in order, then a table
//   node writer.mjs --mode kqueue   just one
//   EXP17_WRITES=3 EXP17_IDLE=5 node writer.mjs --mode poll     smoke test
//
// The app is launched from the built binary rather than `swift run` so that a
// compile never lands inside a measurement window.
// ═════════════════════════════════════════════════════════════════════════════

import { spawn, spawnSync } from "node:child_process";
import {
  appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync,
  realpathSync, renameSync, rmSync, writeFileSync,
} from "node:fs";
import { createInterface } from "node:readline";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const EXPERIMENT_DIR = path.dirname(fileURLToPath(import.meta.url));
const BINARY = path.join(EXPERIMENT_DIR, ".build/release/Exp17");
const RESULTS = path.join(EXPERIMENT_DIR, "artifacts/results.jsonl");
const MODES = ["kqueue", "fsevents", "poll"];

const WRITES = Number(process.env.EXP17_WRITES ?? 20);
const IDLE_SECONDS = Number(process.env.EXP17_IDLE ?? 60);
const GAP_MIN_MS = 1000;
const GAP_MAX_MS = 3000;

// CLOCK_REALTIME with sub-millisecond resolution: timeOrigin is this process's
// start in epoch ms, performance.now() the monotonic offset since. Date.now()
// would quantize every measurement to 1 ms, which is the same order as the
// fastest technique's answer.
const nowEpochMs = () => performance.timeOrigin + performance.now();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const randomGap = () => GAP_MIN_MS + Math.random() * (GAP_MAX_MS - GAP_MIN_MS);

function log(message) {
  console.log(`[writer] ${message}`);
}

/// The daemon's write, exactly: a temp file in the SAME directory (rename is
/// only atomic within a filesystem) renamed over the target. The reader either
/// sees the whole old file or the whole new one, never a half-written number.
function writeAtomically(mfaPath, seq, writeCosts) {
  const number = String(10 + Math.floor(Math.random() * 90));
  const mintedAt = new Date().toISOString();
  const temp = `${mfaPath}.tmp`;
  const t0 = nowEpochMs();
  writeFileSync(temp, JSON.stringify({ number, mintedAt, seq, t0EpochMs: t0 }));
  renameSync(temp, mfaPath);
  writeCosts.push(nowEpochMs() - t0);
  return number;
}

function waitForLine(child, pattern) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`timed out waiting for ${pattern}`)),
      (IDLE_SECONDS + 30) * 1000
    );
    child.stdout.on("line", function onLine(line) {
      if (pattern.test(line)) {
        clearTimeout(timer);
        child.stdout.off("line", onLine);
        resolve(line);
      }
    });
  });
}

async function runMode(mode, root) {
  const cacheDir = path.join(root, "cache");
  const mfaPath = path.join(cacheDir, "mfa.json");
  rmSync(cacheDir, { recursive: true, force: true });
  mkdirSync(cacheDir, { recursive: true });

  log(`── ${mode} ──`);
  const child = spawn(BINARY, [], {
    stdio: ["ignore", "pipe", "inherit"],
    env: {
      ...process.env,
      EXP17_MODE: mode,
      EXP17_ROOT: root,
      EXP17_RESULTS: RESULTS,
      EXP17_IDLE_SECONDS: String(IDLE_SECONDS),
    },
  });
  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    console.log(`[app] ${line}`);
    child.stdout.emit("line", line);
  });

  await waitForLine(child, /^READY/);
  log(`idle window: ${IDLE_SECONDS}s with no writes (measuring standing CPU cost)`);
  await waitForLine(child, /^IDLE-DONE/);

  const writeCosts = [];
  for (let seq = 1; seq <= WRITES; seq += 1) {
    await sleep(randomGap());
    const number = writeAtomically(mfaPath, seq, writeCosts);
    log(`wrote #${seq} → ${number}`);
  }

  await sleep(1500);
  const deleteT0 = nowEpochMs();
  rmSync(mfaPath);
  log("deleted mfa.json");
  await sleep(1500);

  child.kill("SIGTERM");
  await new Promise((resolve) => child.on("exit", resolve));

  // The delete carries no file to stamp, so it is paired up here: the app
  // recorded when it noticed, this process knows when it happened.
  const deleteEvent = readResults()
    .filter((row) => row.technique === mode && row.event === "delete")
    .pop();
  if (deleteEvent) {
    appendFileSync(
      RESULTS,
      `${JSON.stringify({
        technique: mode,
        event: "delete-latency",
        latencyMs: deleteEvent.detectedAtEpochMs - deleteT0,
      })}\n`
    );
  }
  return { writeCosts };
}

function readResults() {
  if (!existsSync(RESULTS)) return [];
  return readFileSync(RESULTS, "utf8")
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

const percentile = (sorted, fraction) =>
  sorted[Math.min(sorted.length - 1, Math.ceil(fraction * sorted.length) - 1)];

function summarize(modes, writeCostsByMode) {
  const rows = readResults();
  const fmt = (n) => (n === undefined ? "—" : n.toFixed(1));

  const columns = [
    ["technique", 10, "left"], ["samples", 8], ["median", 11], ["p95", 11], ["max", 11],
    ["delete", 11], [`idle CPU (${IDLE_SECONDS}s)`, 16], ["spurious", 10], ["dup", 6], ["missed", 8],
  ];
  const row = (cells) =>
    cells
      .map((cell, i) =>
        columns[i][2] === "left"
          ? String(cell).padEnd(columns[i][1])
          : String(cell).padStart(columns[i][1])
      )
      .join("");

  console.log("\n=== experiment 17 — end-to-end pickup latency (file write → icon repainted) ===\n");
  console.log(row(columns.map((column) => column[0])));
  for (const mode of modes) {
    const mine = rows.filter((row) => row.technique === mode);
    const latencies = mine
      .filter((row) => row.event === "update")
      .map((row) => row.latencyMs)
      .sort((a, b) => a - b);
    const idle = mine.find((row) => row.event === "idle-cpu");
    const del = mine.find((row) => row.event === "delete-latency");
    const spurious = mine.filter((row) => row.event === "spurious").length;
    const duplicates = mine.filter((row) => row.event === "duplicate").length;
    const missed = WRITES - latencies.length;
    console.log(
      row([
        mode,
        latencies.length,
        `${fmt(percentile(latencies, 0.5))} ms`,
        `${fmt(percentile(latencies, 0.95))} ms`,
        `${fmt(latencies.at(-1))} ms`,
        `${fmt(del?.latencyMs)} ms`,
        `${fmt(idle?.cpuMs)} ms`,
        spurious,
        duplicates,
        missed,
      ])
    );
  }

  console.log("\nwrite cost (temp write + rename, included in every latency above):");
  for (const mode of modes) {
    const costs = (writeCostsByMode[mode] ?? []).sort((a, b) => a - b);
    if (!costs.length) continue;
    console.log(
      `  ${mode.padEnd(9)} median ${fmt(percentile(costs, 0.5))} ms   max ${fmt(costs.at(-1))} ms`
    );
  }

  const doomed = rows.filter((row) => row.event === "delete" && row.doomedFileWatchArmed);
  for (const row of doomed) {
    console.log(
      `\nfile-level kqueue watch (${row.technique}): armed on the first write, ` +
        `delivered ${row.doomedFileWatchEvents} event(s) [${row.doomedFileWatchFlags}] ` +
        `across the remaining ${WRITES - 1} writes + the delete.`
    );
  }
  console.log(`\nevidence: ${RESULTS}`);
}

async function main() {
  const modeArg = process.argv.indexOf("--mode");
  const modes = modeArg === -1 ? MODES : [process.argv[modeArg + 1]];
  for (const mode of modes) {
    if (!MODES.includes(mode)) throw new Error(`unknown mode '${mode}'`);
  }

  if (!existsSync(BINARY)) {
    log("building…");
    const build = spawnSync("swift", ["build", "-c", "release"], {
      cwd: EXPERIMENT_DIR,
      stdio: "inherit",
    });
    if (build.status !== 0) throw new Error("swift build failed");
  }

  // realpath because FSEvents reports resolved paths and TMPDIR on macOS lives
  // under the /var → /private/var symlink. Never the real BSB_ROOT.
  const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), "exp17-")));
  log(`root: ${root}`);
  mkdirSync(path.dirname(RESULTS), { recursive: true });
  rmSync(RESULTS, { force: true });

  const writeCostsByMode = {};
  try {
    for (const mode of modes) {
      const { writeCosts } = await runMode(mode, root);
      writeCostsByMode[mode] = writeCosts;
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
  summarize(modes, writeCostsByMode);
}

await main();
