/**
 * The full login goes HEADLESS, and its autofill starts waiting for the page.
 *
 * BUILD 2 put the MFA number on the status-bar icon, which retired the only
 * reason the login window existed: a human had to read the digits off the
 * screen. The finished product moment is "the icon shows the number, the human
 * taps their phone, the icon goes back to the logo, nothing else appears". A
 * browser window flashing up at that moment is now a bug, not a feature.
 *
 * The same change removes the thing that was holding the autofill together. A
 * headed run happened to work with `waitForTimeout(2000)` between the email and
 * password steps because a human was watching a real window at human speed; the
 * live run measured what that is actually worth — red validation text under the
 * email field, ~30 seconds of lurching, eventual success by luck. A blind sleep
 * is a bet on Entra's redirect being faster than a number somebody typed once.
 *
 * Priorities these tests defend (everything else was culled):
 *
 *  1. NO WINDOW EVER OPENS UNBIDDEN. The launch decision is the whole feature,
 *     and it is unobservable from a hermetic test the moment it is a literal
 *     buried in a playwright call. So it becomes DATA — a pure function of
 *     (kind, env) that these tests can interrogate directly, with the captures
 *     obtaining their options through it.
 *  2. THE AUTOFILL WAITS FOR THE PAGE, AND SAYS SO WHEN THE PAGE NEVER COMES.
 *     Every step happens because a field reported itself visible, never because
 *     a timer expired; and a field that never appears ends the step with an
 *     honest `false` inside a bounded budget, rather than typing into nothing
 *     and then spending five minutes waiting for an MFA that was never sent.
 *
 * Scope: small. NO BROWSER LAUNCHES, no playwright, no temp root. `browser.mjs`
 * imports playwright lazily (inside `withBrowser`), so this file can import the
 * module itself; what it drives are the pure launch-options function and the
 * field helpers, the latter against a fake page that controls when things
 * become visible.
 *
 * ---------------------------------------------------------------------------
 * THE SEAM THIS FILE PINS — binding on the builder
 * ---------------------------------------------------------------------------
 *
 * `src/rungs/browser.mjs` grows four exports:
 *
 *     launchOptionsFor(kind, env = process.env) -> { headless: boolean }
 *
 *       Pure. `kind` is the rung kind ("silent" | "full"). Headless ALWAYS,
 *       except for kind "full" when `env.BSB_FULL_HEADED === "1"` exactly — the
 *       developer's escape hatch for watching a login go by. Both captures take
 *       their launch options from it, so `headless: false` appears nowhere.
 *
 *     fillWhenReady(page, selectors, value, options) -> Promise<boolean>
 *     clickWhenReady(page, selectors, options) -> Promise<boolean>
 *
 *       The readiness-driven replacements for `fillFirst`/`clickFirst`: try each
 *       selector in list order (the tenant-varies fallback stays), re-check on a
 *       `FIELD_POLL_MS` cadence through `page.waitForTimeout`, act on the first
 *       one that reports visible, and return false — bounded by
 *       `FIELD_TIMEOUT_MS` — when none ever does.
 *
 *       options: { label?: string, log?: (m: string) => void,
 *                  timeoutMs?: number, pollMs?: number }
 *
 *     autofillCredentials(page, { email, password, log, timeoutMs, pollMs })
 *         -> Promise<boolean>
 *
 *       The four-step choreography, extracted from `fullLoginCapture` so it can
 *       be driven without a browser: email → next → password → submit, each step
 *       gated on the previous one and on the field being there. True only when
 *       all four completed.
 *
 *     FIELD_TIMEOUT_MS, FIELD_POLL_MS — the budget and the cadence, exported so
 *       the tests and the caller agree on one source of truth.
 *
 * The polling shape is deliberate rather than `locator.waitFor()`: the selector
 * lists exist because the field's name varies by tenant, and waiting on each
 * candidate in turn would serialize their timeouts.
 *
 * What must NOT move: the MFA poll loop (2s cadence, scrape before auth check,
 * `onMfaNumber` on a change) is pinned by mfa-file.test.mjs and is now the ONLY
 * channel the number has — with the window gone, a scrape that quietly stops
 * working is a login no human can complete.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setTimeout as delay } from "node:timers/promises";
import * as browser from "../src/rungs/browser.mjs";
import { recorder } from "./helpers.mjs";

/**
 * A NAMESPACE import on purpose. Naming these exports directly is a link-time
 * error while they do not exist yet, which collapses the whole file into one
 * failure; read off the namespace, each claim below fails on its own and says
 * which name it wanted.
 */
const {
  FIELD_POLL_MS,
  FIELD_TIMEOUT_MS,
  autofillCredentials,
  clickWhenReady,
  fillWhenReady,
  fullLoginCapture,
  launchOptionsFor,
  silentCapture,
} = browser;

/** The module's own source — for the handful of claims that are about structure. */
const BROWSER_SRC = readFileSync(new URL("../src/rungs/browser.mjs", import.meta.url), "utf8");

/**
 * Does this source text mention it? A boolean, so a structural claim fails with
 * a verdict and its message instead of eight kilobytes of module in the report.
 */
const mentions = (source, pattern) => pattern.test(String(source));

/** The tenant selectors the module ships. The fake keys its fields by these. */
const EMAIL = "input[type=email]";
const EMAIL_ALT = "input[name=loginfmt]";
const PASSWORD = "input[type=password]";
const SUBMIT = "#idSIButton9";

/** Marked, so a leak assertion is a substring search that cannot pass by luck. */
const EMAIL_VALUE = "SECRET-david@purdue.edu";
const PASSWORD_VALUE = "SECRET-password-hunter2";

/** Small enough that a bounded wait is a fast test; a real budget is 30s. */
const FAST = { timeoutMs: 120, pollMs: 5 };

/**
 * A page that never launches a browser but does make things appear late.
 *
 * `fields` maps a selector to when it becomes visible:
 *
 *   { afterChecks: n }  — invisible for the first n visibility checks on it
 *   { afterClick: true } — invisible until something has been clicked (how the
 *                          password field arrives: Entra renders it only after
 *                          the email step is submitted)
 *   a selector that is absent is never visible at all
 *
 * Every operation is recorded in order in `page.calls`, INCLUDING the waits, so
 * "it re-checked instead of sleeping two seconds" is readable off the trace.
 * `fill` and `click` THROW on an invisible element the way playwright does, so
 * an implementation that types before looking cannot pass by accident — and the
 * throw leaves no `fill`/`click` in the trace, so the order assertions see it.
 */
function fakePage(fields = {}) {
  const calls = [];
  const checks = new Map();
  let clicks = 0;

  const seen = (selector) => checks.get(selector) ?? 0;
  const visibleNow = (selector) => {
    const spec = fields[selector];
    if (!spec) return false;
    if (spec.afterClick && clicks === 0) return false;
    return seen(selector) > (spec.afterChecks ?? 0);
  };

  const locator = (selector) => {
    const self = {
      first: () => self,
      isVisible: async () => {
        checks.set(selector, seen(selector) + 1);
        calls.push({ op: "isVisible", selector });
        return visibleNow(selector);
      },
      fill: async (value) => {
        if (!visibleNow(selector)) throw new Error(`filled a field that is not visible: ${selector}`);
        calls.push({ op: "fill", selector, value });
      },
      click: async () => {
        if (!visibleNow(selector)) throw new Error(`clicked a control that is not visible: ${selector}`);
        clicks += 1;
        calls.push({ op: "click", selector });
      },
      textContent: async () => null,
    };
    return self;
  };

  return {
    calls,
    locator,
    waitForTimeout: async (ms) => {
      calls.push({ op: "wait", ms });
      await delay(ms);
    },
  };
}

/** The trace with the visibility polling filtered out: just what was typed and pressed. */
const actions = (page) => page.calls.filter((call) => call.op === "fill" || call.op === "click");

/** Where an operation first happened in the trace, or -1. */
const indexOf = (page, op, selector) =>
  page.calls.findIndex((call) => call.op === op && (selector === undefined || call.selector === selector));

/** Every call recorded between two trace positions. */
const between = (page, from, to) => page.calls.slice(from + 1, to);

// ---------------------------------------------------------------------------
// A. The launch decision, as data.
// ---------------------------------------------------------------------------

test("the silent capture launches headless", () => {
  // Arrange / Act — rung 1 runs from a timer with nobody at the machine.
  const options = launchOptionsFor("silent", {});

  // Assert
  assert.equal(options.headless, true);
});

test("the silent capture stays headless even when the headed escape hatch is set", () => {
  // Arrange / Act — the flag is about watching a LOGIN go by; cron must never
  // pop a window at 3am because a developer left an env var behind.
  const options = launchOptionsFor("silent", { BSB_FULL_HEADED: "1" });

  // Assert
  assert.equal(options.headless, true);
});

test("the full login launches headless by default", () => {
  // Arrange / Act — the whole point of BUILD 2: the icon is the window now.
  const options = launchOptionsFor("full", {});

  // Assert
  assert.equal(options.headless, true);
});

test("the full login opens a window only for the exact opt-in", () => {
  // Arrange / Act — one deliberate escape hatch, for debugging a login.
  const options = launchOptionsFor("full", { BSB_FULL_HEADED: "1" });

  // Assert
  assert.equal(options.headless, false);
});

test("any value other than 1 leaves the full login headless", () => {
  // Arrange — an unset var arrives as undefined, and a shell that exported an
  // empty string, or "0", or "true", meant nothing in particular.
  for (const value of [undefined, "", "0", "true", "false", "yes", "2"]) {
    // Act
    const options = launchOptionsFor("full", { BSB_FULL_HEADED: value });

    // Assert
    assert.equal(options.headless, true, `BSB_FULL_HEADED=${JSON.stringify(value)} opened a window`);
  }
});

test("an unrecognized kind never opens a window", () => {
  // Arrange / Act — a kind nobody planned for is not a reason to show a browser.
  const options = launchOptionsFor("something-new", { BSB_FULL_HEADED: "1" });

  // Assert
  assert.equal(options.headless, true);
});

test("the decision is read from the environment it was handed", () => {
  // Arrange — purity is what makes the flag testable at all: an implementation
  // that reaches for the ambient process cannot be checked without mutating it.
  const previous = process.env.BSB_FULL_HEADED;
  process.env.BSB_FULL_HEADED = "1";
  try {
    // Act
    const options = launchOptionsFor("full", {});

    // Assert
    assert.equal(options.headless, true);
  } finally {
    if (previous === undefined) delete process.env.BSB_FULL_HEADED;
    else process.env.BSB_FULL_HEADED = previous;
  }
});

test("the environment defaults to the process's own", () => {
  // Arrange — production call sites pass a kind and nothing else.
  const previous = process.env.BSB_FULL_HEADED;
  process.env.BSB_FULL_HEADED = "1";
  try {
    // Act
    const options = launchOptionsFor("full");

    // Assert
    assert.equal(options.headless, false);
  } finally {
    if (previous === undefined) delete process.env.BSB_FULL_HEADED;
    else process.env.BSB_FULL_HEADED = previous;
  }
});

test("it answers with launch options, not a bare boolean", () => {
  // Arrange / Act — the value is handed to launchPersistentContext; a boolean
  // would have to be re-wrapped at every call site, which is where a literal
  // `headless: false` grows back.
  const options = launchOptionsFor("full", {});

  // Assert
  assert.equal(typeof options, "object");
  assert.equal(typeof options.headless, "boolean");
});

test("no hard-coded headed launch survives in browser.mjs", () => {
  // Arrange / Act / Assert — the literal that made the full capture headed. The
  // flag has exactly one home now, so the boolean is computed, never written.
  assert.equal(
    mentions(BROWSER_SRC, /headless:\s*false/),
    false,
    "browser.mjs still hard-codes a headed launch",
  );
});

test("the silent capture takes its launch options from launchOptionsFor", () => {
  // Arrange / Act — the capture chooses; withBrowser only launches.
  const source = silentCapture.toString();

  // Assert
  assert.equal(mentions(source, /launchOptionsFor\(/), true, "the silent capture never calls it");
  assert.equal(mentions(source, /headless/), false, "the silent capture still decides for itself");
});

test("the full capture takes its launch options from launchOptionsFor", () => {
  // Arrange / Act
  const source = fullLoginCapture.toString();

  // Assert
  assert.equal(mentions(source, /launchOptionsFor\(/), true, "the full capture never calls it");
  assert.equal(mentions(source, /headless/), false, "the full capture still decides for itself");
});

// ---------------------------------------------------------------------------
// B1. The budget and the cadence.
// ---------------------------------------------------------------------------

test("the poll cadence is a re-check, not a sleep", () => {
  // Arrange / Act / Assert — the 2000ms this build deletes was a guess at how
  // long Entra takes. A cadence is how often the answer is asked for.
  assert.equal(typeof FIELD_POLL_MS, "number", "browser.mjs exports no FIELD_POLL_MS");
  assert.ok(FIELD_POLL_MS > 0, "a zero cadence is a spin loop");
  assert.ok(FIELD_POLL_MS <= 500, `FIELD_POLL_MS is ${FIELD_POLL_MS} — that is a sleep, not a poll`);
});

test("the readiness budget is bounded and generous", () => {
  // Arrange / Act / Assert — long enough that a slow Entra redirect is not
  // called a failure, short enough that a field which is never coming does not
  // cost the human the full five-minute MFA wait to find out.
  assert.equal(typeof FIELD_TIMEOUT_MS, "number", "browser.mjs exports no FIELD_TIMEOUT_MS");
  assert.ok(FIELD_TIMEOUT_MS >= 5_000, `FIELD_TIMEOUT_MS is ${FIELD_TIMEOUT_MS} — too impatient`);
  assert.ok(FIELD_TIMEOUT_MS <= 60_000, `FIELD_TIMEOUT_MS is ${FIELD_TIMEOUT_MS} — unbounded in practice`);
});

// ---------------------------------------------------------------------------
// B2. fillWhenReady — type into a field once it is actually there.
// ---------------------------------------------------------------------------

test("it fills the field with the value it was handed once the field appears", async () => {
  // Arrange — the field is not in the DOM for the first three checks.
  const page = fakePage({ [EMAIL]: { afterChecks: 3 } });

  // Act
  const filled = await fillWhenReady(page, [EMAIL], EMAIL_VALUE, FAST);

  // Assert
  assert.equal(filled, true);
  assert.deepStrictEqual(actions(page), [{ op: "fill", selector: EMAIL, value: EMAIL_VALUE }]);
});

test("it re-checks and waits instead of typing immediately", async () => {
  // Arrange — the live failure was red validation text under the email field:
  // the value went in before Entra had finished rendering the form.
  const page = fakePage({ [EMAIL]: { afterChecks: 3 } });

  // Act
  await fillWhenReady(page, [EMAIL], EMAIL_VALUE, FAST);

  // Assert — the field went visible on the fourth look, and the waits are what
  // separated the looks.
  const before = page.calls.slice(0, indexOf(page, "fill"));
  assert.ok(
    before.filter((call) => call.op === "isVisible" && call.selector === EMAIL).length >= 4,
    "the field was filled without being looked at four times",
  );
  assert.ok(before.some((call) => call.op === "wait"), "it never waited between checks");
});

test("it waits in short re-checks, never a fixed two-second sleep", async () => {
  // Arrange
  const page = fakePage({ [EMAIL]: { afterChecks: 3 } });

  // Act
  await fillWhenReady(page, [EMAIL], EMAIL_VALUE, FAST);

  // Assert — every wait is the cadence it was given.
  for (const wait of page.calls.filter((call) => call.op === "wait")) {
    assert.ok(wait.ms <= FAST.pollMs, `waited ${wait.ms}ms — that is a sleep, not a re-check`);
  }
});

test("it falls back to the tenant's alternate field name", async () => {
  // Arrange — Entra names it loginfmt on some tenants; the fallback list is why
  // the wait polls the selectors rather than waiting on one of them.
  const page = fakePage({ [EMAIL_ALT]: { afterChecks: 2 } });

  // Act
  const filled = await fillWhenReady(page, [EMAIL, EMAIL_ALT], EMAIL_VALUE, FAST);

  // Assert
  assert.equal(filled, true);
  assert.deepStrictEqual(actions(page), [{ op: "fill", selector: EMAIL_ALT, value: EMAIL_VALUE }]);
});

test("it reports false when the field never appears", { timeout: 5_000 }, async () => {
  // Arrange — the page went somewhere else entirely. Hanging here is the worst
  // outcome: a daemon nobody can see, holding a browser open.
  const page = fakePage({});

  // Act
  const filled = await fillWhenReady(page, [EMAIL, EMAIL_ALT], EMAIL_VALUE, FAST);

  // Assert
  assert.equal(filled, false);
  assert.deepStrictEqual(actions(page), []);
});

test("it waits out its budget before giving up", { timeout: 5_000 }, async () => {
  // Arrange — a single glance and a `false` would be the old fillFirst wearing
  // a new name.
  const page = fakePage({});

  // Act
  await fillWhenReady(page, [EMAIL], EMAIL_VALUE, FAST);

  // Assert
  assert.ok(
    page.calls.filter((call) => call.op === "isVisible").length > 1,
    "it gave up after one look",
  );
});

test("it never puts the value it typed in the log", async () => {
  // Arrange — the same helper types the password, and the daemon's log is
  // stderr, a file the Swift app spawned, and a terminal David screenshots.
  const page = fakePage({ [PASSWORD]: { afterChecks: 0 } });
  const journal = recorder();

  // Act
  await fillWhenReady(page, [PASSWORD], PASSWORD_VALUE, {
    ...FAST,
    label: "password",
    log: journal.log,
  });

  // Assert
  assert.ok(!journal.text().includes(PASSWORD_VALUE), "the password reached the log");
});

// ---------------------------------------------------------------------------
// B3. clickWhenReady — press the button once it is actually there.
// ---------------------------------------------------------------------------

test("it clicks the button once it appears", async () => {
  // Arrange
  const page = fakePage({ [SUBMIT]: { afterChecks: 2 } });

  // Act
  const clicked = await clickWhenReady(page, [SUBMIT], { ...FAST, label: "email-next" });

  // Assert
  assert.equal(clicked, true);
  assert.deepStrictEqual(actions(page), [{ op: "click", selector: SUBMIT }]);
});

test("it reports false when no button ever appears", { timeout: 5_000 }, async () => {
  // Arrange
  const page = fakePage({});

  // Act
  const clicked = await clickWhenReady(page, [SUBMIT], { ...FAST, label: "email-next" });

  // Assert
  assert.equal(clicked, false);
  assert.deepStrictEqual(actions(page), []);
});

// ---------------------------------------------------------------------------
// B4. autofillCredentials — the four steps, each one because of the last.
// ---------------------------------------------------------------------------

/** Entra's real shape: the password field exists only after the email is submitted. */
const loginPage = () =>
  fakePage({
    [EMAIL]: { afterChecks: 1 },
    [SUBMIT]: { afterChecks: 0 },
    [PASSWORD]: { afterClick: true, afterChecks: 2 },
  });

test("it types the email, submits it, types the password, and submits that", async () => {
  // Arrange
  const page = loginPage();

  // Act
  await autofillCredentials(page, {
    email: EMAIL_VALUE,
    password: PASSWORD_VALUE,
    log: () => {},
    ...FAST,
  });

  // Assert — the whole choreography, in order, with the polling filtered out.
  assert.deepStrictEqual(actions(page), [
    { op: "fill", selector: EMAIL, value: EMAIL_VALUE },
    { op: "click", selector: SUBMIT },
    { op: "fill", selector: PASSWORD, value: PASSWORD_VALUE },
    { op: "click", selector: SUBMIT },
  ]);
});

test("the password is typed only after its field has appeared", async () => {
  // Arrange — the field does not exist at the moment the email is submitted.
  const page = loginPage();

  // Act
  await autofillCredentials(page, {
    email: EMAIL_VALUE,
    password: PASSWORD_VALUE,
    log: () => {},
    ...FAST,
  });

  // Assert — the password field was looked for, repeatedly, in between.
  const submitted = indexOf(page, "click", SUBMIT);
  const typed = indexOf(page, "fill", PASSWORD);
  const looks = between(page, submitted, typed).filter(
    (call) => call.op === "isVisible" && call.selector === PASSWORD,
  );
  assert.ok(looks.length >= 3, `the password field was checked ${looks.length} times before typing`);
});

test("no blind two-second sleep sits between the email step and the password step", async () => {
  // Arrange — this is the line the build deletes: `await page.waitForTimeout(2000)`
  // between the email-next click and the password fill.
  const page = loginPage();

  // Act
  await autofillCredentials(page, {
    email: EMAIL_VALUE,
    password: PASSWORD_VALUE,
    log: () => {},
    ...FAST,
  });

  // Assert
  const submitted = indexOf(page, "click", SUBMIT);
  const typed = indexOf(page, "fill", PASSWORD);
  const waits = between(page, submitted, typed).filter((call) => call.op === "wait");
  assert.ok(waits.length > 0, "the password step did not wait for the field at all");
  for (const wait of waits) {
    assert.ok(wait.ms <= FAST.pollMs, `slept ${wait.ms}ms between steps instead of re-checking`);
  }
});

test("it reports success only when all four steps completed", async () => {
  // Arrange
  const page = loginPage();

  // Act
  const done = await autofillCredentials(page, {
    email: EMAIL_VALUE,
    password: PASSWORD_VALUE,
    log: () => {},
    ...FAST,
  });

  // Assert
  assert.equal(done, true);
});

test("it reports failure when the email field never appears", { timeout: 5_000 }, async () => {
  // Arrange — the profile landed somewhere unexpected: a consent screen, an
  // error page, a tenant that changed its form.
  const page = fakePage({ [SUBMIT]: { afterChecks: 0 } });

  // Act
  const done = await autofillCredentials(page, {
    email: EMAIL_VALUE,
    password: PASSWORD_VALUE,
    log: () => {},
    ...FAST,
  });

  // Assert — and nothing was typed anywhere, least of all the password.
  assert.equal(done, false);
  assert.deepStrictEqual(actions(page), []);
});

test("it reports failure when the password field never appears", { timeout: 5_000 }, async () => {
  // Arrange — the email was rejected, or Entra went straight to a different
  // challenge. Reporting true here buys a five-minute wait for an MFA prompt
  // that was never sent.
  const page = fakePage({ [EMAIL]: { afterChecks: 0 }, [SUBMIT]: { afterChecks: 0 } });

  // Act
  const done = await autofillCredentials(page, {
    email: EMAIL_VALUE,
    password: PASSWORD_VALUE,
    log: () => {},
    ...FAST,
  });

  // Assert — the email step still happened; the password one honestly did not.
  assert.equal(done, false);
  assert.deepStrictEqual(actions(page), [
    { op: "fill", selector: EMAIL, value: EMAIL_VALUE },
    { op: "click", selector: SUBMIT },
  ]);
});

test("it never puts the password in the log", async () => {
  // Arrange — D7: the password is typed into the page and never spoken.
  const page = loginPage();
  const journal = recorder();

  // Act
  await autofillCredentials(page, {
    email: EMAIL_VALUE,
    password: PASSWORD_VALUE,
    log: journal.log,
    ...FAST,
  });

  // Assert
  assert.ok(!journal.text().includes(PASSWORD_VALUE), "the password reached the log");
});

test("the full capture drives its autofill through autofillCredentials", () => {
  // Arrange / Act — the choreography lives in one testable place; a second copy
  // inlined in the capture is a second thing to go wrong unobserved.
  const source = fullLoginCapture.toString();

  // Assert
  assert.equal(
    mentions(source, /autofillCredentials\(/),
    true,
    "the full capture still inlines its own fill/click sequence",
  );
});

// ---------------------------------------------------------------------------
// C. The number still gets out. With the window gone, this is the only channel.
// ---------------------------------------------------------------------------

test("the number scrape survives the headless refactor", () => {
  // Arrange / Act / Assert — a headless browser makes the scrape MORE
  // load-bearing, not less: nobody can read the digits off the screen now.
  assert.equal(
    mentions(BROWSER_SRC, /#idRichContext_DisplaySign/),
    true,
    "the MFA number selector is gone — the icon has nothing to show",
  );
});

test("the full capture still announces the number it scrapes", () => {
  // Arrange / Act — mfa-file.test.mjs pins what the RUNG does with the
  // announcement; this pins that the capture still makes one.
  const source = fullLoginCapture.toString();

  // Assert
  assert.equal(mentions(source, /onMfaNumber/), true, "the capture announces nothing to the icon");
});
