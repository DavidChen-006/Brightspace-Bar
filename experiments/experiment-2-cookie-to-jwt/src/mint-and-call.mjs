/**
 * Experiment 2 — the two-function seam between the test and the network.
 *
 * The test owns orchestration, JWT decoding, assertions, and observability.
 * These two functions own ONLY the HTTP. Spike 2 (the builder) implements them.
 *
 * Contract:
 *
 *   mintJwt({ baseUrl, cookieHeader, csrfToken })
 *     POST {baseUrl}/d2l/lp/auth/oauth2/token
 *       content-type: application/x-www-form-urlencoded
 *       cookie: <cookieHeader>
 *       x-csrf-token: <csrfToken>   // omit the header entirely when csrfToken is null/undefined
 *       body: scope=*:*:*
 *     returns { status, accessToken, expiresAt, raw }
 *       - status:      HTTP status number
 *       - accessToken: the JWT string (or null on non-200)
 *       - expiresAt:   the response's expires_at (unix seconds, or null)
 *       - raw:         the parsed JSON response body (for logging / debugging)
 *
 *   callApi({ baseUrl, jwt, path })
 *     GET {baseUrl}{path}  with  Authorization: Bearer <jwt>
 *     returns { status, body }
 *       - status: HTTP status number
 *       - body:   the parsed JSON response body
 *
 * Never log the cookie, the CSRF token, or the full JWT anywhere in here.
 */

const HTTP_TIMEOUT_MS = 30_000;

/** Parse a response body as JSON when it is JSON, otherwise return raw text. */
async function readBody(res) {
  const text = await res.text();
  const type = res.headers.get('content-type') ?? '';
  if (type.includes('application/json') || type.includes('+json')) {
    try {
      return JSON.parse(text);
    } catch {
      return text;
    }
  }
  return text;
}

export async function mintJwt({ baseUrl, cookieHeader, csrfToken }) {
  const headers = {
    'content-type': 'application/x-www-form-urlencoded',
    cookie: cookieHeader,
  };
  if (csrfToken != null) headers['x-csrf-token'] = csrfToken;

  const res = await fetch(`${baseUrl}/d2l/lp/auth/oauth2/token`, {
    method: 'POST',
    headers,
    body: 'scope=*:*:*',
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });

  const raw = await readBody(res);
  const json = raw && typeof raw === 'object' ? raw : null;
  return {
    status: res.status,
    accessToken: res.status === 200 ? (json?.access_token ?? null) : null,
    expiresAt: json?.expires_at ?? null,
    raw,
  };
}

export async function callApi({ baseUrl, jwt, path }) {
  const res = await fetch(`${baseUrl}${path}`, {
    method: 'GET',
    headers: { authorization: `Bearer ${jwt}` },
    signal: AbortSignal.timeout(HTTP_TIMEOUT_MS),
  });

  return { status: res.status, body: await readBody(res) };
}
