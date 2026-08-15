/**
 * Rung 1 — silent Entra SSO. Kind "silent": no human, so a timer spawn may climb
 * it and cron never pops a window.
 *
 * The mechanics are experiment 10's, behind an injectable seam: the persistent
 * profile holds the Microsoft Entra cookie (~90 days), and a dead D2L session
 * re-mints itself against it with zero input. Everything playwright is in
 * `browser.mjs`; everything about the credential file is in `capture-rung.mjs`.
 */
import { createCaptureRung } from "./capture-rung.mjs";
import { silentCapture } from "./browser.mjs";

/** @param {{capture?: Function, baseUrl?: string}} [deps] */
export const createSilentRung = ({ capture = silentCapture, baseUrl } = {}) =>
  createCaptureRung({ kind: "silent", capture, baseUrl });
