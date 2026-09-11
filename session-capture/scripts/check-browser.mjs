#!/usr/bin/env node
/**
 * Exit 0 when Playwright's Chromium is completely installed, 1 with the fix
 * when it is not. `make setup` runs this after `npm install`, so "Setup
 * complete" is only printed when the daemon can actually launch a browser.
 */
import { chromium } from "playwright";
import { installProblem } from "../src/browser-install.mjs";

const problem = installProblem(chromium.executablePath());
if (problem) {
  console.error(`error: ${problem}`);
  process.exit(1);
}
console.error("daemon browser: Chromium is installed (headless shell and full)");
