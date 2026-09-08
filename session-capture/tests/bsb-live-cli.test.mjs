/**
 * `bsb`'s live commands, end to end, against a FAKE tenant: a local HTTP
 * server standing in for Brightspace, a session.json pointing at it. No
 * network leaves the machine and no browser starts, yet the whole path runs
 * — argv → session.json → token mint → bearer GET → parse → stdout/file →
 * exit code — exactly as it does against the real tenant.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { run, tempPaths } from "./helpers.mjs";

const TOKEN = "SECRET-BEARER";
const COOKIE = "d2lSessionVal=SECRET-COOKIE";

const TOC = {
  Modules: [
    {
      Title: "Course Information",
      Topics: [{ TopicId: 100, Title: "Syllabus Fall 2026", TypeIdentifier: "File", Url: "/content/enforced/1/syllabus.pdf" }],
      Modules: [],
    },
    {
      Title: "Week 1",
      Topics: [
        { TopicId: 101, Title: "Slides 1", TypeIdentifier: "Link", Url: "https://docs.example/slides" },
        { TopicId: 102, Title: "Reading 1", TypeIdentifier: "File", Url: "/content/enforced/1/reading.txt" },
      ],
      Modules: [],
    },
  ],
};

/** The tenant: a table of routes, plus a switch that kills the session. */
async function tenant(t, { expired = false } = {}) {
  const seen = [];
  const server = createServer((request, response) => {
    seen.push({ method: request.method, url: request.url, authorization: request.headers.authorization });
    const answer = (status, body, headers = { "content-type": "application/json" }) => {
      response.writeHead(status, headers);
      response.end(body);
    };
    if (request.url === "/d2l/lp/auth/oauth2/token") {
      if (request.method !== "POST" || request.headers.cookie !== COOKIE) return answer(403, "Not authenticated", { "content-type": "text/plain" });
      if (expired) return answer(200, "<html><script>location='/d2l/login?sessionExpired=1'</script></html>", { "content-type": "text/html" });
      return answer(200, JSON.stringify({ access_token: TOKEN }));
    }
    if (request.headers.authorization !== `Bearer ${TOKEN}`) return answer(401, "no bearer", { "content-type": "text/plain" });
    if (request.method !== "GET") return answer(405, "GET only", { "content-type": "text/plain" });
    switch (request.url) {
      case "/d2l/api/le/1.96/1/content/toc": return answer(200, JSON.stringify(TOC));
      case "/d2l/api/le/1.96/1/overview": return answer(200, JSON.stringify({ Description: { Text: "Welcome.\nMidterm on Oct 6." } }));
      case "/d2l/api/le/1.96/2/overview": return answer(404, "<html>no overview</html>", { "content-type": "text/html" });
      case "/d2l/api/le/1.96/2/content/toc": return answer(200, JSON.stringify({ Modules: [] }));
      case "/d2l/api/le/1.96/1/content/topics/100/file":
        return answer(200, "%PDF-1.4 fake syllabus", { "content-type": "application/pdf", "content-disposition": "attachment; filename*=UTF-8''Syllabus%20Fall%202026.pdf; filename=\"Syllabus Fall 2026.pdf\"" });
      case "/d2l/api/le/1.96/1/content/topics/102/file":
        return answer(200, "read me\n", { "content-type": "text/plain", "content-disposition": "attachment; filename=\"reading.txt\"" });
      case "/d2l/api/le/1.96/1/grades/values/myGradeValues/":
        return answer(200, JSON.stringify([{ GradeObjectIdentifier: "1", GradeObjectName: "Lab 1", GradeObjectTypeName: "Numeric", DisplayedGrade: "9 / 10", PointsNumerator: 9, PointsDenominator: 10 }]));
      case "/d2l/api/lp/1.62/users/whoami": return answer(200, JSON.stringify({ Identifier: "1", UniqueName: "student" }));
      default: return answer(404, "<html>not found</html>", { "content-type": "text/html" });
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(() => server.close());
  const baseUrl = `http://127.0.0.1:${server.address().port}`;

  const paths = tempPaths(t);
  mkdirSync(paths.cacheDir, { recursive: true });
  writeFileSync(paths.sessionFile, JSON.stringify({ baseUrl, cookieHeader: COOKIE, csrfToken: "SECRET-CSRF" }));
  return { paths, baseUrl, seen };
}

const bsb = (paths, args, extra = {}) =>
  run("node", ["src/bsb.mjs", ...args], { ...extra, env: { ...process.env, BSB_ROOT: paths.root, ...(extra.env ?? {}) } });

test("content lists the table of contents with topic ids, types and module paths", async (t) => {
  const { paths } = await tenant(t);
  const result = await bsb(paths, ["content", "--course", "1", "--json"]);
  assert.equal(result.code, 0, result.stderr);
  const rows = JSON.parse(result.stdout);
  assert.deepEqual(rows.map((r) => [r.topicId, r.type, r.module]), [
    [100, "File", "Course Information"], [101, "Link", "Week 1"], [102, "File", "Week 1"],
  ]);
  const human = await bsb(paths, ["content", "--course", "1"]);
  assert.match(human.stdout, /100\s+File\s+Syllabus Fall 2026\s+Course Information/);
  assert.match(human.stdout, /https:\/\/docs\.example\/slides/);
});

test("fetch downloads a File topic under the server's own filename", async (t) => {
  const { paths } = await tenant(t);
  const dir = path.join(paths.root, "downloads");
  mkdirSync(dir);
  const result = await bsb(paths, ["fetch", "--course", "1", "--topic", "100", "--out", dir, "--json"]);
  assert.equal(result.code, 0, result.stderr);
  const { file, bytes, contentType } = JSON.parse(result.stdout);
  assert.equal(path.basename(file), "Syllabus Fall 2026.pdf");
  assert.equal(contentType, "application/pdf");
  assert.equal(bytes, 22);
  assert.equal(readFileSync(file, "utf8"), "%PDF-1.4 fake syllabus");

  const named = await bsb(paths, ["fetch", "--course", "1", "--topic", "102", "--out", path.join(dir, "r.txt")]);
  assert.equal(named.code, 0, named.stderr);
  assert.equal(readFileSync(path.join(dir, "r.txt"), "utf8"), "read me\n");

  const streamed = await bsb(paths, ["fetch", "--course", "1", "--topic", "102", "--stdout"]);
  assert.equal(streamed.stdout, "read me\n");
});

test("syllabus gathers the overview text and downloads every topic named like one", async (t) => {
  const { paths } = await tenant(t);
  const dir = path.join(paths.root, "syllabus");   // does not exist yet — must be created as a directory
  const result = await bsb(paths, ["syllabus", "--course", "1", "--out", dir, "--json"]);
  assert.equal(result.code, 0, result.stderr);
  const found = JSON.parse(result.stdout);
  assert.equal(found.overviewText, "Welcome.\nMidterm on Oct 6.");
  assert.equal(found.files.length, 1);
  assert.equal(path.basename(found.files[0].file), "Syllabus Fall 2026.pdf");
  assert.equal(path.dirname(found.files[0].file), dir);
  assert.deepEqual(readdirSync(dir), ["Syllabus Fall 2026.pdf"]);
  assert.deepEqual(found.links, []);

  const human = await bsb(paths, ["syllabus", "--course", "1", "--out", dir]);
  assert.match(human.stdout, /Course overview/);
  assert.match(human.stdout, /saved .*Syllabus Fall 2026\.pdf/);
});

test("syllabus on a course with neither says so, and overview 404 is not an error", async (t) => {
  const { paths } = await tenant(t);
  const result = await bsb(paths, ["syllabus", "--course", "2"]);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /No syllabus found/);
  const overview = await bsb(paths, ["overview", "--course", "2"]);
  assert.equal(overview.code, 0);
  assert.match(overview.stdout, /no overview/);
  const text = await bsb(paths, ["overview", "--course", "1"]);
  assert.equal(text.stdout, "Welcome.\nMidterm on Oct 6.\n");
});

test("grades and api read through the same session; api refuses other hosts and non-API paths", async (t) => {
  const { paths, baseUrl, seen } = await tenant(t);
  const grades = await bsb(paths, ["grades", "--course", "1"]);
  assert.equal(grades.code, 0, grades.stderr);
  assert.match(grades.stdout, /9 \/ 10\s+9\/10\s+Lab 1/);

  const who = await bsb(paths, ["api", "lp:users/whoami"]);
  assert.equal(who.code, 0, who.stderr);
  assert.equal(JSON.parse(who.stdout).UniqueName, "student");
  const full = await bsb(paths, ["api", `${baseUrl}/d2l/api/lp/1.62/users/whoami`, "--out", path.join(paths.root, "who.json")]);
  assert.equal(full.code, 0, full.stderr);
  assert.equal(JSON.parse(readFileSync(path.join(paths.root, "who.json"), "utf8")).Identifier, "1");

  const other = await bsb(paths, ["api", "https://evil.example/d2l/api/x"]);
  assert.equal(other.code, 1);
  assert.match(other.stderr, /not on this session's tenant/);
  const page = await bsb(paths, ["api", "/d2l/home/1"]);
  assert.equal(page.code, 1);
  assert.match(page.stderr, /only the read API is exposed/);
  const missing = await bsb(paths, ["api", "le:1/nope"]);
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /HTTP 404/);

  // Everything the fake tenant saw was a GET with the bearer, or the one mint.
  for (const request of seen) {
    if (request.url === "/d2l/lp/auth/oauth2/token") continue;
    assert.equal(request.method, "GET");
    assert.equal(request.authorization, `Bearer ${TOKEN}`);
  }
});

test("a dead session is exit 2 and names bsb refresh, on every live command", async (t) => {
  const { paths } = await tenant(t, { expired: true });
  for (const args of [["content", "--course", "1"], ["syllabus", "--course", "1"], ["grades", "--course", "1"], ["api", "lp:users/whoami"], ["fetch", "--course", "1", "--topic", "100"]]) {
    const result = await bsb(paths, args);
    assert.equal(result.code, 2, `${args.join(" ")}: ${result.stderr}`);
    assert.match(result.stderr, /session is expired.*bsb refresh/);
    assert.doesNotMatch(result.stderr, /SECRET/);
  }
});

test("a root with no session.json is exit 2 too, and nothing is contacted", async (t) => {
  const { paths, seen } = await tenant(t);
  writeFileSync(paths.sessionFile, "");
  const result = await bsb(paths, ["content", "--course", "1"]);
  assert.equal(result.code, 2);
  assert.deepEqual(seen, []);
});

test("refresh runs the daemon's ladder and returns its exit code", async (t) => {
  const { paths } = await tenant(t);
  // A stand-in refresh.mjs: proves the spawn, the argument pass-through and
  // the exit code without a browser. It records argv where the test can read it.
  const stub = path.join(paths.root, "refresh-stub.mjs");
  writeFileSync(stub, `import { writeFileSync } from "node:fs";
writeFileSync(process.env.STUB_OUT, JSON.stringify(process.argv.slice(2)));
process.exit(2);`);
  const out = path.join(paths.root, "argv.json");
  const result = await bsb(paths, ["refresh", "--no-full-login"], { env: { BSB_REFRESH_CLI: stub, STUB_OUT: out } });
  assert.equal(result.code, 2);
  assert.deepEqual(JSON.parse(readFileSync(out, "utf8")), ["--no-full-login"]);
  assert.match(result.stderr, /silent rungs only/);
  const full = await bsb(paths, ["refresh"], { env: { BSB_REFRESH_CLI: stub, STUB_OUT: out } });
  assert.deepEqual(JSON.parse(readFileSync(out, "utf8")), []);
  assert.match(full.stderr, /MFA number/);
});
