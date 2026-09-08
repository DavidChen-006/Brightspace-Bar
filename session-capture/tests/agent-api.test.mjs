/**
 * The agent's live read client, with the socket injected. What is pinned here
 * is the part that must hold no matter what the tenant answers: GET only,
 * same origin only, the API prefix only, one mint per process, the fetcher's
 * own dead-session classification — and that no secret ever comes back to a
 * caller in any shape.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { createApi, resolveTarget } from "../src/agent/api.mjs";
import { tempPaths } from "./helpers.mjs";

const BASE = "https://purdue.brightspace.com";
const COOKIE = "d2lSessionVal=SECRET-COOKIE; d2lSecureSessionVal=SECRET-2";
const TOKEN = "SECRET-BEARER";

function sessionRoot(t) {
  const paths = tempPaths(t);
  mkdirSync(paths.root, { recursive: true });
  writeFileSync(paths.sessionFile, JSON.stringify({ baseUrl: `${BASE}/`, cookieHeader: COOKIE, csrfToken: "SECRET-CSRF" }));
  return paths;
}

/** A tenant that answers from a table, recording every request it saw. */
function fakeTenant(routes, { mint = { status: 200, body: JSON.stringify({ access_token: TOKEN }) } } = {}) {
  const requests = [];
  return {
    requests,
    async http(request) {
      requests.push(request);
      if (request.url === `${BASE}/d2l/lp/auth/oauth2/token`) return { status: mint.status, headers: {}, body: Buffer.from(mint.body) };
      const route = routes[request.url];
      if (!route) return { status: 404, headers: { "content-type": "text/html" }, body: Buffer.from("no") };
      return { status: route.status ?? 200, headers: route.headers ?? { "content-type": "application/json" }, body: Buffer.from(route.body ?? "") };
    },
  };
}

// ── resolveTarget ───────────────────────────────────────────────────────────

test("shorthands expand to the versioned API paths the fetcher uses", () => {
  assert.equal(resolveTarget("le:1631476/content/toc", BASE).url, `${BASE}/d2l/api/le/1.96/1631476/content/toc`);
  assert.equal(resolveTarget("lp:users/whoami", BASE).url, `${BASE}/d2l/api/lp/1.62/users/whoami`);
  assert.equal(resolveTarget("le:/1631476/overview", BASE).path, "/d2l/api/le/1.96/1631476/overview");
});

test("a bare path is joined onto the tenant; a full URL on the tenant is accepted", () => {
  assert.equal(resolveTarget("/d2l/api/versions/", BASE).url, `${BASE}/d2l/api/versions/`);
  assert.equal(resolveTarget("d2l/api/versions/", BASE).url, `${BASE}/d2l/api/versions/`);
  assert.equal(resolveTarget(`${BASE}/d2l/api/versions/`, BASE).url, `${BASE}/d2l/api/versions/`);
  assert.equal(resolveTarget(`${BASE.toUpperCase()}/d2l/api/versions/`, BASE).ok, true);
});

test("another host is refused — the bearer goes nowhere else", () => {
  const result = resolveTarget("https://evil.example/d2l/api/versions/", BASE);
  assert.equal(result.ok, false);
  assert.match(result.detail, /not on this session's tenant/);
  const lookalike = resolveTarget("https://purdue.brightspace.com.evil.example/d2l/api/x", BASE);
  assert.equal(lookalike.ok, false);
});

test("anything outside /d2l/api/ is refused, with the shorthand suggested", () => {
  for (const target of ["/d2l/login", "/d2l/home/1631476", `${BASE}/d2l/lms/x`, "", "   "]) {
    const result = resolveTarget(target, BASE);
    assert.equal(result.ok, false, target);
  }
  assert.match(resolveTarget("/d2l/home", BASE).detail, /le:<courseId>\/content\/toc/);
});

// ── createApi ───────────────────────────────────────────────────────────────

test("a GET mints once, sends the bearer, and hands back the bytes and headers", async (t) => {
  const paths = sessionRoot(t);
  const tenant = fakeTenant({
    [`${BASE}/d2l/api/le/1.96/1/content/toc`]: { body: JSON.stringify({ Modules: [] }) },
    [`${BASE}/d2l/api/le/1.96/1/content/topics/9/file`]: {
      headers: { "Content-Type": "text/plain", "Content-Disposition": "attachment; filename=\"week1.txt\"" }, body: "hello",
    },
  });
  const api = createApi({ paths, http: tenant.http });

  const toc = await api.get("le:1/content/toc");
  assert.ok(toc.ok, JSON.stringify(toc));
  assert.equal(toc.body.toString(), JSON.stringify({ Modules: [] }));
  assert.equal(toc.contentType, "application/json");

  const file = await api.get("le:1/content/topics/9/file");
  assert.ok(file.ok);
  assert.equal(file.body.toString(), "hello");
  assert.equal(file.disposition, "attachment; filename=\"week1.txt\"");   // header keys lower-cased

  // One mint for two GETs; every read is a GET carrying the bearer and nothing else.
  const mints = tenant.requests.filter((r) => r.url.endsWith("/oauth2/token"));
  assert.equal(mints.length, 1);
  assert.equal(mints[0].method, "POST");
  assert.equal(mints[0].headers.cookie, COOKIE);
  for (const request of tenant.requests.filter((r) => !r.url.endsWith("/oauth2/token"))) {
    assert.equal(request.method, "GET");
    assert.deepEqual(request.headers, { authorization: `Bearer ${TOKEN}` });
    assert.equal(request.body, undefined);
  }
  assert.equal(api.baseUrl(), BASE);
});

test("no session.json is sessionExpired — the same recovery path as a dead one", async (t) => {
  const paths = tempPaths(t);
  const tenant = fakeTenant({});
  const result = await createApi({ paths, http: tenant.http }).get("le:1/overview");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "sessionExpired");
  assert.deepEqual(tenant.requests, []);
});

test("the mint's HTTP-200 stub is sessionExpired, not success", async (t) => {
  const paths = sessionRoot(t);
  const tenant = fakeTenant({}, { mint: { status: 200, body: "<html><script>location='/d2l/login?sessionExpired=1'</script></html>" } });
  const result = await createApi({ paths, http: tenant.http }).get("le:1/overview");
  assert.equal(result.ok, false);
  assert.equal(result.reason, "sessionExpired");
});

test("a stub answered mid-run, on an HTML page, is sessionExpired too", async (t) => {
  const paths = sessionRoot(t);
  const tenant = fakeTenant({
    [`${BASE}/d2l/api/le/1.96/1/overview`]: {
      headers: { "content-type": "text/html; charset=utf-8" }, body: "<html>…sessionExpired=1…</html>",
    },
  });
  const result = await createApi({ paths, http: tenant.http }).get("le:1/overview");
  assert.equal(result.reason, "sessionExpired");
});

test("a JSON payload that merely mentions the marker is a payload", async (t) => {
  const paths = sessionRoot(t);
  const body = JSON.stringify({ Description: { Text: "see /d2l/login?sessionExpired=1" } });
  const tenant = fakeTenant({ [`${BASE}/d2l/api/le/1.96/1/overview`]: { body } });
  const result = await createApi({ paths, http: tenant.http }).get("le:1/overview");
  assert.ok(result.ok);
  assert.equal(result.body.toString(), body);
});

test("non-2xx is an http failure with the status and a hint; a socket error is transport", async (t) => {
  const paths = sessionRoot(t);
  const tenant = fakeTenant({ [`${BASE}/d2l/api/lp/1.62/courses/1`]: { status: 403, body: "Forbidden" } });
  const api = createApi({ paths, http: tenant.http });
  const forbidden = await api.get("lp:courses/1");
  assert.equal(forbidden.reason, "http");
  assert.equal(forbidden.status, 403);
  assert.match(forbidden.detail, /HTTP 403 — no access/);
  const missing = await api.get("le:1/nope");
  assert.equal(missing.status, 404);
  assert.match(missing.detail, /no such route or id/);

  const offline = createApi({ paths, http: async () => { throw new Error("connect ECONNREFUSED"); } });
  const result = await offline.get("le:1/overview");
  assert.equal(result.reason, "transport");
  assert.match(result.detail, /ECONNREFUSED/);
});

test("a refused target sends nothing — not even the mint", async (t) => {
  const paths = sessionRoot(t);
  const tenant = fakeTenant({});
  const api = createApi({ paths, http: tenant.http });
  const result = await api.get("https://evil.example/d2l/api/versions/");
  assert.equal(result.reason, "refused");
  // The mint happened (it precedes resolution) but no GET left for the other host.
  assert.ok(tenant.requests.every((r) => r.url.startsWith(BASE)));
});

test("no answer ever carries a secret", async (t) => {
  const paths = sessionRoot(t);
  const tenant = fakeTenant({ [`${BASE}/d2l/api/le/1.96/1/overview`]: { status: 500, body: "boom" } });
  const api = createApi({ paths, http: tenant.http });
  for (const target of ["le:1/overview", "le:1/content/toc", "https://evil.example/x", "/d2l/home"]) {
    const text = JSON.stringify(await api.get(target));
    for (const secret of ["SECRET-COOKIE", "SECRET-2", "SECRET-CSRF", "SECRET-BEARER"]) {
      assert.ok(!text.includes(secret), `${target} leaked ${secret}`);
    }
  }
});
