/**
 * `cache/mfa.json` — the number on its way to the status-bar icon.
 *
 * The icon is a PURE FUNCTION of (the file exists && now - mintedAt < 60s), so
 * this file's lifetime IS what the human sees. It exists only while a number is
 * actually live on the login page: written the moment the scrape succeeds,
 * rewritten when a resend mints a different one, and gone before the attempt
 * resolves. A file that outlives its number is an icon telling a human to type
 * digits that will not work.
 *
 * D7: status, never a credential. The number is display-by-design and useless
 * without the phone — nothing else from the login may ever land here, because
 * `cache/` is the unprivileged directory the Swift app watches.
 */
import { rmSync } from "node:fs";
import { writeJsonAtomic } from "../atomic-write.mjs";

/**
 * The file's whole lifecycle, as two effects the rung drives.
 *
 * Both are guarded: the icon is a SIDE CHANNEL, so a full disk or an unwritable
 * cache directory must not take down a login the human is halfway through, and
 * must not turn a captured session into a rung that threw.
 *
 * @param {{file: string, clock: () => Date, log: (m: string) => void}} deps
 */
export function createMfaPublisher({ file, clock, log }) {
  const guarded = (verb, action) => {
    try {
      action();
    } catch (error) {
      log(`could not ${verb} mfa.json: ${String(error?.message ?? error)}`);
    }
  };

  return {
    /** Announce the number now on the screen. Awaited by the capture. */
    async publish(text) {
      // textContent arrives with the template's whitespace, and an EMPTY element
      // is the scrape failing rather than a number: an empty icon reads as a
      // broken app, which is strictly worse than the logo.
      const number = String(text ?? "").trim();
      if (!number) return;
      guarded("write", () => writeJsonAtomic(file, { number, mintedAt: clock().toISOString() }));
    },

    /** No number is live. Safe when the file — or `cache/` itself — is absent. */
    clear() {
      guarded("remove", () => rmSync(file, { force: true }));
    },
  };
}
