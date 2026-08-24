# Seed issues to open on GitHub

Draft issues to publish so the Issues tab isn't empty at launch (checklist
70–73). Each is written to be self-contained. Suggested labels are noted;
create the labels first (`bug`, `enhancement`, `documentation`,
`good first issue`, `help wanted`).

---

## 1. Generalise the login beyond Purdue (configurable SAML entityId)

**Labels:** `enhancement`, `help wanted`

**Current behavior.** The SAML IdP entityId is hardcoded to Purdue's Shibboleth
in `session-capture/src/browser-open.mjs` (`SAML_ENTITY_ID`) and the login flow
assumes Purdue's campus-selector page.

**Desired behavior.** Read the entityId (and any campus-selector text) from
configuration — an env var and/or a small config file — so students at other
D2L/Brightspace schools can use the app.

**Relevant files.** `session-capture/src/browser-open.mjs`,
`session-capture/src/login-flow.mjs`.

**Acceptance criteria.** Purdue still works with zero config; a documented env
var points the flow at a different IdP; README's "Purdue-specific" note is
updated.

---

## 2. Quiet the ended-course 403 spam during `make start`

**Labels:** `enhancement`, `good first issue`

**Current behavior.** `make start` prints two `HTTP 403` lines per ended course
(dozens of lines) because ended courses reject the fetch by policy (see
`experiments/experiment-6-ended-course-access`). It buries the real output.

**Desired behavior.** Ended/inaccessible courses are summarised (e.g. "23
ended courses skipped") instead of two lines each, or logged only at a verbose
level.

**Relevant files.** the fetch loop in `session-capture/src/fetch-engine.mjs`.

**Acceptance criteria.** A normal `make start` shows a concise summary; the
per-course detail is still reachable behind a verbose flag; tests updated.

---

## 3. Fix stale references in `session-capture/README.md`

**Labels:** `documentation`, `good first issue`

**Current behavior.** The daemon README still refers to a `node_modules`
symlink into `experiment-1-fresh-cookie` and other paths that changed when the
experiments moved to the `experiments` branch. At least one claim ("node_modules
is a symlink…") is stale independent of the move.

**Desired behavior.** References match the current layout; the symlink claim is
corrected to reflect the real `npm install`.

**Relevant files.** `session-capture/README.md`.

**Acceptance criteria.** Every path and claim in that README is accurate against
the current tree.

---

## 4. Add a `make clean` target

**Labels:** `enhancement`, `good first issue`

**Current behavior.** No target removes build products; contributors delete
`BrightspaceBar/.build` by hand.

**Desired behavior.** `make clean` removes Swift build products (and optionally
the daemon's `node_modules`), documented in the Makefile help.

**Relevant files.** top-level `Makefile`, `BrightspaceBar/Makefile`.

**Acceptance criteria.** `make clean` leaves a working tree that `make setup &&
make test` restores; no source touched.

---

## 5. Replace the default menu-bar icon

**Labels:** `enhancement`, `good first issue`, `help wanted`

**Current behavior.** The status item uses the SF Symbol `book.closed`
(`StatusBarController`, `iconSymbolName`).

**Desired behavior.** A distinctive icon (custom template PDF or a better SF
Symbol) that reads clearly at menu-bar size in light and dark.

**Relevant files.** `BrightspaceBar/Modules/BrightspaceBar/Sources/StatusBarController.swift`.

**Acceptance criteria.** The icon is legible on both menu-bar appearances and
does not clip; the MFA-number takeover still works.

---

## 6. Undo affordance for a deleted manual item

**Labels:** `enhancement`

**Current behavior.** Deleting a manual item via the popup ✕ is immediate with
no confirmation (by design) and no undo.

**Desired behavior.** A brief undo path (e.g. a transient "Undo" menu entry, or
a short-lived restore) so an accidental ✕ is recoverable — the original design
intent (Intent 4) called for undo rather than a confirm dialog.

**Relevant files.** `ManualItemStore`, the popup delete wiring in
`GraphDayPopup.swift` and `main.swift`.

**Acceptance criteria.** An accidental delete can be reversed within a short
window; no confirmation dialog is added; tests cover the restore.
