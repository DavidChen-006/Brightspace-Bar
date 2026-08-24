/**
 * The session.json output contract, as pure functions.
 *
 * Everything that consumes a captured session — `BrightspaceBar`'s
 * `FileSessionProvider`, every experiment probe — reads these four fields, so the
 * shape is decided in exactly one place and is testable without a browser.
 *
 * Provenance: these two functions originate in
 * `../experiments/experiment-1-fresh-cookie/src/acquire-session.mjs`, where they were written and
 * proven. That folder is a frozen experiment record and keeps its own copy; this
 * is the live definition that tooling depends on. The duplication is deliberate —
 * importing across a folder we might one day delete would be a latent trap, and a
 * frozen file cannot drift.
 */

/**
 * Build a RAW HTTP Cookie header value (no "cookie:" prefix) from the two D2L
 * session cookies, in a stable order.
 *
 * The order is fixed rather than incidental so two captures of the same session
 * produce byte-identical headers — which is what lets a diff of session.json mean
 * "the session changed" rather than "the cookie jar iterated differently".
 *
 * @param {{name: string, value: string}[]} cookies
 * @returns {string}
 */
export function buildCookieHeader(cookies) {
  const order = ["d2lSessionVal", "d2lSecureSessionVal"];
  return cookies
    .filter((c) => order.includes(c.name))
    .sort((a, b) => order.indexOf(a.name) - order.indexOf(b.name))
    .map((c) => `${c.name}=${c.value}`)
    .join("; ");
}

/**
 * Assemble the session.json output contract.
 *
 * `capturedAt` is milliseconds since the epoch, and is what
 * `refresh-session.sh` reports an age from — the only honest thing to print
 * about a credential file.
 *
 * @param {{baseUrl: string, cookies: {name: string, value: string}[],
 *          csrfToken: string | null, landedUrl: string, capturedAt: number}} facts
 * @returns {object}
 */
export function buildSession({ baseUrl, cookies, csrfToken, landedUrl, capturedAt }) {
  return {
    capturedAt,
    baseUrl,
    cookieHeader: buildCookieHeader(cookies),
    cookies: cookies.map((c) => ({ name: c.name, value: c.value })),
    csrfToken,
    landedUrl,
  };
}
