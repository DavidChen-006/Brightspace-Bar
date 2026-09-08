/**
 * The agent's live read of Brightspace, through the daemon's own session.
 *
 * The fetcher (`fetch-engine.mjs`) reads a handful of routes into the
 * data.json contract. An agent wants the rest — a course's table of contents,
 * the syllabus file behind a topic, the overview text, the gradebook values —
 * and the LMS has a read API for every one of them. This client is the
 * daemon's session (`session.json` → token mint → bearer) opened to any GET
 * under `/d2l/api/`, so the agent authenticates the way the app does and the
 * app's invariants hold over it:
 *
 *   - **GET only, structurally.** There is no method parameter. The one
 *     non-GET this module can send is the token mint the fetcher sends too.
 *   - **Same origin only.** A path is joined onto the session's own base URL;
 *     a full URL is accepted only when it starts with that base. The bearer
 *     token never travels to another host.
 *   - **D7.** The cookie, the CSRF token and the bearer are read, sent, and
 *     never returned to a caller, never logged, never in an error message.
 *
 * Session death is classified exactly as the fetcher classifies it: the mint
 * answers HTTP 200 with a redirect stub carrying `sessionExpired=1`. That is
 * `reason: "sessionExpired"`, and the CLI turns it into exit 2 and "run
 * `bsb refresh`" — the ladder is the daemon's, not this module's.
 */
import {
  EXPIRED_MARKER, LE_VERSION, LP_VERSION, decodeMint, mintRequest, readCredentials,
} from "../fetch-engine.mjs";

const API_PREFIX = "/d2l/api/";

/**
 * @param {{paths: {sessionFile: string},
 *          http?: (request: {method: string, url: string, headers: object, body?: string})
 *            => Promise<{status: number, headers: Record<string, string>, body: Buffer}>}} deps
 */
export function createApi({ paths, http = nodeHttp }) {
  let credentials = null;
  let token = null;

  /** Cookie → bearer, once per process. */
  async function bearer() {
    if (token) return { ok: true };
    credentials ??= readCredentials(paths.sessionFile);
    if (!credentials) return { ok: false, reason: "sessionExpired", detail: "no session.json" };
    const minted = await send(http, mintRequest(credentials));
    if (!minted.ok) return minted;
    const mint = decodeMint({ status: minted.status, body: minted.body.toString("utf8") });
    if (mint.expired) return { ok: false, reason: "sessionExpired", detail: "the token mint answered with the sessionExpired stub" };
    if (!mint.token) return { ok: false, reason: "transport", detail: mint.detail };
    token = mint.token;
    return { ok: true };
  }

  return {
    /** The session's tenant, e.g. `https://purdue.brightspace.com`, or null before any session. */
    baseUrl() {
      credentials ??= readCredentials(paths.sessionFile);
      return credentials?.baseUrl ?? null;
    },

    /**
     * One authenticated GET. `target` is an API path (`/d2l/api/le/1.96/…`),
     * a shorthand (`le:1631476/content/toc`, `lp:users/whoami`), or a full
     * URL on the session's own origin.
     *
     * @returns {Promise<{ok: true, status: number, contentType: string,
     *   disposition: string | null, body: Buffer}
     *   | {ok: false, reason: "sessionExpired" | "transport" | "http" | "refused",
     *      status?: number, detail: string}>}
     */
    async get(target) {
      const ready = await bearer();
      if (!ready.ok) return ready;
      const resolved = resolveTarget(target, credentials.baseUrl);
      if (!resolved.ok) return resolved;
      const answer = await send(http, {
        method: "GET",
        url: resolved.url,
        headers: { authorization: `Bearer ${token}` },
      });
      if (!answer.ok) return answer;
      const contentType = answer.headers["content-type"] ?? "";
      // A token that died between two calls comes back as the same stub the
      // mint would have sent, on an HTML page — never inside a JSON payload.
      if (answer.status === 200 && /text\/html/i.test(contentType)
        && answer.body.toString("utf8", 0, 4096).includes(EXPIRED_MARKER)) {
        return { ok: false, reason: "sessionExpired", detail: "the session expired mid-run" };
      }
      if (answer.status < 200 || answer.status >= 300) {
        return {
          ok: false, reason: "http", status: answer.status,
          detail: `${resolved.path} answered HTTP ${answer.status}${statusHint(answer.status)}`,
        };
      }
      return {
        ok: true,
        status: answer.status,
        contentType,
        disposition: answer.headers["content-disposition"] ?? null,
        body: answer.body,
      };
    },
  };
}

/**
 * Where a request may go. Everything an agent can name resolves to a path
 * under `/d2l/api/` on the session's own origin, or is refused — with the
 * reason, because "refused" alone teaches an agent nothing.
 */
export function resolveTarget(target, baseUrl) {
  const raw = String(target ?? "").trim();
  if (!raw) return { ok: false, reason: "refused", detail: "no path given" };
  let path;
  const shorthand = /^(le|lp):(.*)$/.exec(raw);
  if (shorthand) {
    const version = shorthand[1] === "le" ? LE_VERSION : LP_VERSION;
    path = `${API_PREFIX}${shorthand[1]}/${version}/${shorthand[2].replace(/^\/+/, "")}`;
  } else if (/^https?:\/\//i.test(raw)) {
    if (!raw.toLowerCase().startsWith(`${baseUrl.toLowerCase()}/`)) {
      return { ok: false, reason: "refused", detail: `${raw} is not on this session's tenant (${baseUrl}); the bearer token goes nowhere else` };
    }
    path = raw.slice(baseUrl.length);
  } else {
    path = raw.startsWith("/") ? raw : `/${raw}`;
  }
  if (!path.startsWith(API_PREFIX)) {
    return { ok: false, reason: "refused", detail: `${path} is not under ${API_PREFIX} — only the read API is exposed (try \`le:<courseId>/content/toc\` or a full /d2l/api/ path)` };
  }
  return { ok: true, path, url: `${baseUrl}${path}` };
}

function statusHint(status) {
  if (status === 403) return " — no access (an ended course, or a tool the course does not enable)";
  if (status === 404) return " — no such route or id";
  return "";
}

/** The only socket. Anything that stops a response is transport, never success. */
async function send(http, request) {
  try {
    const { status, headers, body } = await http(request);
    return { ok: true, status, headers: lowerKeys(headers ?? {}), body: toBuffer(body) };
  } catch (error) {
    return { ok: false, reason: "transport", detail: String(error?.message ?? error) };
  }
}

/** Global fetch, bytes out. Node strips the bearer on a cross-origin redirect by spec. */
async function nodeHttp({ method, url, headers, body }) {
  const response = await fetch(url, { method, headers, body });
  return {
    status: response.status,
    headers: Object.fromEntries(response.headers.entries()),
    body: Buffer.from(await response.arrayBuffer()),
  };
}

const lowerKeys = (headers) =>
  Object.fromEntries(Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]));

const toBuffer = (body) =>
  Buffer.isBuffer(body) ? body : Buffer.from(typeof body === "string" ? body : String(body ?? ""));
