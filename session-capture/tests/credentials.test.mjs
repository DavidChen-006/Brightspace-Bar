/**
 * credentials.mjs — the one lookup the full-login rung trusts.
 *
 * The priority order IS the contract: env when both vars are set, the stored
 * file otherwise, null when neither is whole. Get that wrong and either a
 * stale file overrides a deliberate export, or half a credential autofills a
 * login form. The other two claims are about custody: the file lands 0600
 * (it holds a password on David's disk), and the prompt refuses a non-TTY
 * stdin so no headless spawn can hang — or be fed a password by a pipe.
 *
 * Hermetic like everything else here: env is passed in explicitly, the file
 * lives under a temp BSB_ROOT, and no test touches the real Library root.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { credentialsFile, loadCredentials, saveCredentials } from "../src/credentials.mjs";
import { PKG_DIR, run, tempDir } from "./helpers.mjs";

const CREDS = { email: "student@purdue.edu", password: "hunter2-but-longer" };

test("resolves credentials.json directly under BSB_ROOT", (t) => {
  // Arrange
  const root = tempDir(t);

  // Act / Assert
  assert.equal(credentialsFile({ BSB_ROOT: root }), `${root}/credentials.json`);
});

test("env wins over the file when BOTH vars are set", (t) => {
  // Arrange
  const root = tempDir(t);
  saveCredentials({ email: "file@purdue.edu", password: "file-pass" }, { BSB_ROOT: root });

  // Act
  const loaded = loadCredentials({ BSB_ROOT: root, BS_EMAIL: CREDS.email, BS_PASSWORD: CREDS.password });

  // Assert
  assert.deepStrictEqual(loaded, CREDS);
});

test("half an env credential does not count — the file answers instead", (t) => {
  // Arrange
  const root = tempDir(t);
  saveCredentials(CREDS, { BSB_ROOT: root });

  // Act
  const loaded = loadCredentials({ BSB_ROOT: root, BS_EMAIL: "only-email@purdue.edu" });

  // Assert
  assert.deepStrictEqual(loaded, CREDS);
});

test("falls back to the stored file when env is empty", (t) => {
  // Arrange
  const root = tempDir(t);
  saveCredentials(CREDS, { BSB_ROOT: root });

  // Act / Assert
  assert.deepStrictEqual(loadCredentials({ BSB_ROOT: root }), CREDS);
});

test("returns null when neither env nor file has credentials", (t) => {
  // Arrange
  const root = tempDir(t);

  // Act / Assert
  assert.equal(loadCredentials({ BSB_ROOT: root }), null);
});

test("returns null on a corrupt or incomplete file rather than throwing", (t) => {
  // Arrange
  const root = tempDir(t);
  writeFileSync(`${root}/credentials.json`, '{"email": "no-password@purdue.edu"}');

  // Act / Assert
  assert.equal(loadCredentials({ BSB_ROOT: root }), null);
});

test("saves the file with mode 0600 — it holds a password", (t) => {
  // Arrange
  const root = tempDir(t);

  // Act
  const file = saveCredentials(CREDS, { BSB_ROOT: root });

  // Assert
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.deepStrictEqual(JSON.parse(readFileSync(file, "utf8")), CREDS);
});

test("re-saving tightens an existing looser file to 0600", (t) => {
  // Arrange — an older build may have left the file world-readable.
  const root = tempDir(t);
  const file = `${root}/credentials.json`;
  writeFileSync(file, "{}", { mode: 0o644 });

  // Act
  saveCredentials(CREDS, { BSB_ROOT: root });

  // Assert
  assert.equal(statSync(file).mode & 0o777, 0o600);
});

test("promptForCredentials refuses when stdin is not a TTY", async (t) => {
  // Arrange — a child with piped stdio has no TTY, exactly like a daemon spawn.
  const root = tempDir(t);
  const script = `
    import { promptForCredentials } from "${PKG_DIR}/src/credentials.mjs";
    try { await promptForCredentials(); console.log("PROMPTED"); }
    catch (e) { console.error(e.message); process.exit(3); }
  `;

  // Act
  const result = await run(process.execPath, ["--input-type=module", "-e", script], {
    env: { ...process.env, BSB_ROOT: root, BS_EMAIL: "", BS_PASSWORD: "" },
  });

  // Assert
  assert.equal(result.code, 3, `expected the TTY refusal, got: ${result.stdout} ${result.stderr}`);
  assert.match(result.stderr, /not a TTY/);
  assert.ok(!result.stdout.includes("PROMPTED"));
});
