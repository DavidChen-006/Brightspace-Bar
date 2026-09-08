/**
 * The skill (skills/brightspace-bar) is documentation an agent acts on, so
 * it is held to the CLI the way a test holds code: every `bsb <command>` it
 * names must exist, its frontmatter must be the Agent Skills shape, and its
 * shim must reach the CLI through a symlink — which is how `make skill`
 * installs it.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, readlinkSync, symlinkSync } from "node:fs";
import path from "node:path";
import { PKG_DIR, run, tempDir } from "./helpers.mjs";

const SKILL_DIR = path.join(PKG_DIR, "..", "skills", "brightspace-bar");
const SKILL = readFileSync(path.join(SKILL_DIR, "SKILL.md"), "utf8");

/** The commands the CLI really has, read off its own --help. */
async function cliCommands() {
  const help = await run("node", ["src/bsb.mjs", "--help"]);
  assert.equal(help.code, 0);
  const commands = new Set();
  for (const line of help.stdout.split("\n")) {
    const match = /^  ([a-z]+) /.exec(line);
    if (match) commands.add(match[1]);
  }
  return commands;
}

test("the frontmatter is the Agent Skills shape and the name matches the directory", () => {
  const frontmatter = /^---\n([\s\S]*?)\n---\n/.exec(SKILL);
  assert.ok(frontmatter, "SKILL.md must start with YAML frontmatter");
  const name = /^name:\s*(.+)$/m.exec(frontmatter[1])?.[1].trim();
  assert.equal(name, path.basename(SKILL_DIR));
  assert.match(name, /^[a-z0-9]+(-[a-z0-9]+)*$/);
  const description = /^description:\s*(.+)$/m.exec(frontmatter[1])?.[1].trim();
  assert.ok(description && description.length > 0 && description.length <= 1024);
  for (const keyword of ["Brightspace", "D2L", "syllabus", "due dates", "grades"]) {
    assert.match(description, new RegExp(keyword), `the description never says ${keyword}`);
  }
});

test("SKILL.md stays under the spec's 500 lines, and its references exist", () => {
  assert.ok(SKILL.split("\n").length < 500);
  for (const reference of SKILL.matchAll(/\]\((references\/[^)]+)\)/g)) {
    assert.ok(readdirSync(path.join(SKILL_DIR, "references")).includes(path.basename(reference[1])), reference[1]);
  }
});

test("every bsb command the skill names exists, and every command the CLI has is named", async () => {
  const real = await cliCommands();
  const named = new Set();
  for (const file of ["SKILL.md", "references/items.md", "references/endpoints.md"]) {
    const text = readFileSync(path.join(SKILL_DIR, file), "utf8");
    for (const match of text.matchAll(/\bbsb ([a-z]+)\b/g)) named.add(match[1]);
  }
  for (const command of named) {
    assert.ok(real.has(command), `the skill names \`bsb ${command}\`, which the CLI does not have`);
  }
  for (const command of real) {
    assert.ok(named.has(command), `the CLI has \`bsb ${command}\`, which the skill never mentions`);
  }
});

test("the skill never tells an agent to write to Brightspace", () => {
  for (const verb of ["POST", "PUT", "DELETE", "PATCH"]) {
    // The verbs may appear only in the sentence that forbids them.
    for (const line of SKILL.split("\n").filter((l) => l.includes(verb))) {
      assert.match(line, /never|not|only|GET/i, `SKILL.md line mentions ${verb} outside a prohibition: ${line}`);
    }
  }
  assert.match(SKILL, /never writes to Brightspace/i);
});

test("a COPIED skill (npx skills add) finds the checkout via BSB_REPO or the recorded path, else says how", async (t) => {
  // Arrange — copy the skill somewhere with no checkout above it, as the
  // skills CLI does, and hide the home-directory fallback.
  const { cpSync, mkdirSync, writeFileSync } = await import("node:fs");
  const elsewhere = tempDir(t);
  const copy = path.join(elsewhere, "brightspace-bar");
  cpSync(SKILL_DIR, copy, { recursive: true });
  const root = path.join(elsewhere, "root");
  const shim = path.join(copy, "scripts", "bsb");
  const env = { ...process.env, HOME: path.join(elsewhere, "nohome"), BSB_ROOT: root };
  delete env.BSB_REPO;

  // Act / Assert — nothing to go on: a refusal that names every place it looked and the fix.
  const lost = await run(shim, ["--help"], { cwd: elsewhere, env });
  assert.equal(lost.code, 1);
  assert.match(lost.stderr, /cannot find the Brightspace Bar checkout/);
  assert.match(lost.stderr, /make setup/);

  // BSB_REPO wins.
  const repo = path.resolve(PKG_DIR, "..");
  const explicit = await run(shim, ["--help"], { cwd: elsewhere, env: { ...env, BSB_REPO: repo } });
  assert.equal(explicit.code, 0, explicit.stderr);
  assert.match(explicit.stdout, /Usage: bsb/);

  // The one-line file `make setup` writes.
  mkdirSync(root, { recursive: true });
  writeFileSync(path.join(root, "checkout"), `${repo}\n`);
  const recorded = await run(shim, ["--help"], { cwd: elsewhere, env });
  assert.equal(recorded.code, 0, recorded.stderr);
  assert.match(recorded.stdout, /Usage: bsb/);

  // And the arguments arrive untouched (the first one is not eaten by the resolver).
  const status = await run(shim, ["frobnicate"], { cwd: elsewhere, env });
  assert.match(status.stderr, /unknown command "frobnicate"/);
});

test("the project-level .claude/skills entry is a symlink to the skill, so an agent in the repo needs no install", () => {
  const link = path.join(PKG_DIR, "..", ".claude", "skills", "brightspace-bar");
  assert.equal(path.resolve(path.dirname(link), readlinkSync(link)), path.resolve(SKILL_DIR));
});

test("scripts/bsb reaches the CLI, directly and through the symlink make skill plants", async (t) => {
  const direct = await run(path.join(SKILL_DIR, "scripts", "bsb"), ["--help"]);
  assert.equal(direct.code, 0, direct.stderr);
  assert.match(direct.stdout, /Usage: bsb/);

  const skills = tempDir(t);
  const link = path.join(skills, "brightspace-bar");
  symlinkSync(SKILL_DIR, link);
  const linked = await run(path.join(link, "scripts", "bsb"), ["--help"], { cwd: skills });
  assert.equal(linked.code, 0, linked.stderr);
  assert.match(linked.stdout, /Usage: bsb/);
});
