/**
 * Rung 2 — the headed login. Kind "full": it puts a browser in front of a human
 * who reads the MFA number off the screen and types it into their phone, so the
 * orchestrator only climbs it when the caller proved a human is present
 * (`--allow-full-login`, passed by the manual Refresh click).
 *
 * The mechanics are `auto-capture.mjs`'s, per D3: headed, autofilling
 * BS_EMAIL/BS_PASSWORD, generous MFA wait. Everything playwright is in
 * `browser.mjs`; everything about the credential file is in `capture-rung.mjs`.
 */
import { createCaptureRung } from "./capture-rung.mjs";
import { fullLoginCapture } from "./browser.mjs";

/** @param {{capture?: Function, baseUrl?: string}} [deps] */
export const createFullLoginRung = ({ capture = fullLoginCapture, baseUrl } = {}) =>
  createCaptureRung({ kind: "full", capture, baseUrl });
