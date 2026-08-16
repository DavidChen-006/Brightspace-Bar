/**
 * Rung 2 — the full login. Kind "full": it needs a human at their phone to
 * approve a number-match, so the orchestrator only climbs it when the caller
 * proved a human is present (`--allow-full-login`, passed by the manual Refresh
 * click). Nothing is shown to that human except the number on the status-bar
 * icon — the browser itself runs headless (D3 as amended by BUILD 3).
 *
 * The mechanics are `auto-capture.mjs`'s: autofilling BS_EMAIL/BS_PASSWORD,
 * generous MFA wait. Everything playwright is in `browser.mjs`; everything
 * about the credential file is in `capture-rung.mjs`.
 *
 * This rung owns one more thing, because it is the only rung a human watches:
 * `cache/mfa.json`, the number on its way to the status-bar icon. The capture
 * merely ANNOUNCES a number through `onMfaNumber`; the write, the update on a
 * resend and — on every way out, including a browser that explodes mid-flow —
 * the deletion all happen here. That is also what keeps the single-writer rule
 * structural: the silent rung is built without the publisher and so cannot
 * publish a number at 3am with nobody's phone involved.
 */
import { createCaptureRung } from "./capture-rung.mjs";
import { fullLoginCapture } from "./browser.mjs";
import { createMfaPublisher } from "./mfa-file.mjs";

/** @param {{capture?: Function, baseUrl?: string, clock?: () => Date}} [deps] */
export function createFullLoginRung({
  capture = fullLoginCapture,
  baseUrl,
  clock = () => new Date(),
} = {}) {
  return {
    kind: "full",
    /** @param {{paths: object, log: (m: string) => void}} world */
    async attempt(world) {
      const mfa = createMfaPublisher({ file: world.paths.mfaFile, clock, log: world.log });
      const rung = createCaptureRung({
        kind: "full",
        capture: (browserWorld) => capture({ ...browserWorld, onMfaNumber: mfa.publish }),
        baseUrl,
      });

      // The previous run may have been SIGKILLed with its number on the icon.
      // The TTL covers the icon; this attempt must still not begin against a lie.
      mfa.clear();
      try {
        return await rung.attempt(world);
      } finally {
        mfa.clear();
      }
    },
  };
}
