/**
 * The agent's write surface — and the ONLY thing the agent surface ever
 * writes: `$BSB_ROOT/manual-items.json`, the student's own items, which the
 * Swift `ManualItemStore` also reads and writes. Nothing here can reach
 * Brightspace; a "write" in this CLI is a write to the bar.
 *
 * The file contract is the Swift module's, transcribed, and it is strict in a
 * way that makes THIS module's validation load-bearing: `ManualItemStore`
 * decodes the whole array with `.iso8601` dates and a closed `Kind` enum, and
 * one entry it cannot decode quarantines the ENTIRE file — every item the
 * student ever typed vanishes from the menu until someone repairs it. So an
 * agent's mistake must be caught before the write, never after: unknown kind,
 * unknown course, unparseable date, blank link — each is refused here with a
 * sentence the agent can act on.
 *
 * Writes are temp+rename in the same directory (`atomic-write.mjs`), which is
 * also what the app's `DataWatcher` keys on to repaint the menu the moment the
 * file lands.
 *
 * Shape of one entry, as the app writes it (sorted keys, whole-second UTC):
 *
 *   { "courseId": 1631476, "due": "2026-10-06T03:59:00Z",
 *     "id": "2F2A…-uppercase UUID", "kind": "quiz",
 *     "link": "https://…", "name": "Midterm 1" }
 */
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import path from "node:path";
import { writeJsonAtomic } from "../atomic-write.mjs";

/** `ManualItem.Kind`, verbatim. A fourth case here without one in Swift is a quarantined file. */
export const KINDS = ["assignment", "quiz", "test"];

/**
 * What an agent (or a syllabus) is likely to call each kind. Resolved
 * case-insensitively; anything not listed is refused rather than guessed,
 * because "lab" could mean a graded assignment or an in-lab exam.
 */
const KIND_ALIASES = {
  assignment: "assignment",
  homework: "assignment",
  hw: "assignment",
  project: "assignment",
  quiz: "quiz",
  test: "test",
  exam: "test",
  midterm: "test",
  final: "test",
};

/** Beside `session.json`, at the root — never under `cache/`, which the daemon owns. */
export function manualItemsFile(paths) {
  return path.join(paths.root, "manual-items.json");
}

/**
 * The file as it stands. Missing → empty (the Swift store's P2). Corrupt or
 * off-contract → `ok: false`, and the caller must NOT write: the Swift side
 * would quarantine such a file on its next read, and an overwrite from here
 * would destroy the bytes it was going to preserve.
 *
 * @returns {{ok: true, items: object[]} | {ok: false, detail: string}}
 */
export function readManualItems(file) {
  let raw;
  try {
    raw = readFileSync(file, "utf8");
  } catch {
    return { ok: true, items: [] };
  }
  let items;
  try {
    items = JSON.parse(raw);
  } catch {
    return { ok: false, detail: `${file} is not JSON — the app will quarantine it as manual-items.json.corrupt on its next read; fix or remove it by hand` };
  }
  if (!Array.isArray(items)) return { ok: false, detail: `${file} is not a JSON array` };
  for (const [index, item] of items.entries()) {
    const problem = offContract(item);
    if (problem) return { ok: false, detail: `${file} entry ${index} ${problem}` };
  }
  return { ok: true, items };
}

/** Why one stored entry would fail the Swift decoder, or null when it would not. */
function offContract(item) {
  if (!item || typeof item !== "object") return "is not an object";
  if (typeof item.id !== "string" || !item.id) return "has no id";
  if (!Number.isInteger(item.courseId)) return "has no integer courseId";
  if (!KINDS.includes(item.kind)) return `has unknown kind ${JSON.stringify(item.kind)}`;
  if (typeof item.name !== "string") return "has no name";
  if (typeof item.link !== "string" || !item.link.trim()) return "has an empty link";
  if (typeof item.due !== "string" || Number.isNaN(Date.parse(item.due))) return "has an unreadable due date";
  return null;
}

/**
 * A due date as a person or an agent writes one, onto the whole-second UTC
 * ISO string the file carries. Accepted, in the LOCAL zone of this process
 * unless the text carries its own zone:
 *
 *   2026-10-06               → that day at 23:59 local (Brightspace's own
 *                              default, and the add-form's seed value)
 *   2026-10-06 14:30         → that local time (a "T" separator works too)
 *   2026-10-06T14:30:00Z     → exactly that instant
 *   2026-10-06T14:30:00-04:00
 *
 * Anything else is null — refused upstream, never defaulted, because a wrong
 * day on a heatmap is worse than no square.
 */
export function parseDue(text) {
  if (typeof text !== "string") return null;
  const trimmed = text.trim();
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(trimmed);
  if (dateOnly) return localInstant(dateOnly[1], dateOnly[2], dateOnly[3], 23, 59, 0);
  const local = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})(?::(\d{2}))?$/.exec(trimmed);
  if (local) return localInstant(local[1], local[2], local[3], local[4], local[5], local[6] ?? 0);
  const zoned = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})$/.test(trimmed);
  if (!zoned) return null;
  const at = new Date(trimmed);
  return Number.isNaN(at.getTime()) ? null : isoSeconds(at);
}

/** Calendar components in the process zone → instant, refusing rollover (2026-02-30). */
function localInstant(y, mo, d, h, mi, s) {
  const [year, month, day, hour, minute, second] = [y, mo, d, h, mi, s].map(Number);
  const at = new Date(year, month - 1, day, hour, minute, second);
  const same = at.getFullYear() === year && at.getMonth() === month - 1 && at.getDate() === day
    && at.getHours() === hour && at.getMinutes() === minute;
  return same ? isoSeconds(at) : null;
}

const isoSeconds = (at) => `${at.toISOString().slice(0, 19)}Z`;

/** The kind a word means, or null. */
export function resolveKind(text) {
  return KIND_ALIASES[String(text ?? "").trim().toLowerCase()] ?? null;
}

/**
 * One draft → one item the Swift decoder will accept, or the list of
 * everything wrong with it. Every check runs, so an agent that got three
 * things wrong hears about all three in one round trip.
 *
 * @param {{courseId: unknown, kind: unknown, title?: unknown, name?: unknown,
 *          due: unknown, link?: unknown}} draft
 * @param {{courses: {id: number, name: string}[], baseUrl: string,
 *          id?: () => string}} world
 */
export function draftToItem(draft, { courses, baseUrl, id = newId }) {
  const errors = [];
  const courseId = Number(draft?.courseId);
  if (!Number.isInteger(courseId)) {
    errors.push(`courseId must be an integer (got ${JSON.stringify(draft?.courseId)})`);
  } else if (!courses.some((course) => course.id === courseId)) {
    errors.push(`course ${courseId} is not one of your enrollments (run \`bsb courses --all\` to see the ids)`);
  }
  const kind = resolveKind(draft?.kind);
  if (!kind) {
    errors.push(`kind must be one of ${KINDS.join(", ")} (got ${JSON.stringify(draft?.kind)})`);
  }
  const name = String(draft?.title ?? draft?.name ?? "").trim();
  if (!name) errors.push("title is required");
  const due = parseDue(draft?.due);
  if (!due) {
    errors.push(`due must be YYYY-MM-DD, "YYYY-MM-DD HH:MM", or a full ISO-8601 instant (got ${JSON.stringify(draft?.due)})`);
  }
  let link = draft?.link === undefined || draft?.link === null ? null : String(draft.link);
  if (link !== null && !link.trim()) {
    errors.push("link may be omitted but not blank");
  }
  if (link === null && Number.isInteger(courseId)) link = `${baseUrl}/d2l/home/${courseId}`;
  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, item: { courseId, due, id: id(), kind, link, name } };
}

/** Swift's `UUID().uuidString` is uppercase; match it so the file reads as one hand wrote it. */
const newId = () => randomUUID().toUpperCase();

/** What makes two items "the same" to an agent re-running a syllabus import. */
const duplicateKey = (item) =>
  `${item.courseId}|${item.kind}|${item.name.trim().toLowerCase()}|${item.due}`;

/**
 * Append, all-or-nothing, skipping exact duplicates unless told otherwise. An
 * agent that imports the same syllabus twice must not double every square;
 * `allowDuplicate` exists for the student who really does have two things
 * called "Quiz" on one day.
 *
 * Refuses to touch a file `readManualItems` cannot vouch for.
 *
 * @returns {{ok: true, added: object[], skipped: object[], all: object[]} | {ok: false, detail: string}}
 */
export function addItems(file, items, { allowDuplicate = false } = {}) {
  const existing = readManualItems(file);
  if (!existing.ok) return existing;
  const seen = new Set(existing.items.map(duplicateKey));
  const added = [];
  const skipped = [];
  for (const item of items) {
    const key = duplicateKey(item);
    if (!allowDuplicate && seen.has(key)) {
      skipped.push(item);
      continue;
    }
    seen.add(key);
    added.push(item);
  }
  const all = [...existing.items, ...added];
  if (added.length > 0) writeJsonAtomic(file, all);
  return { ok: true, added, skipped, all };
}

/**
 * Remove by id, or every item of one course. Unknown ids are reported, not
 * errors: the file is exactly as asked for afterwards either way.
 *
 * @returns {{ok: true, removed: object[], missing: string[], all: object[]} | {ok: false, detail: string}}
 */
export function removeItems(file, { ids = [], courseId = null } = {}) {
  const existing = readManualItems(file);
  if (!existing.ok) return existing;
  const wanted = new Set(ids.map((id) => String(id).toUpperCase()));
  const removed = [];
  const kept = [];
  for (const item of existing.items) {
    const byId = wanted.has(item.id.toUpperCase());
    const byCourse = courseId !== null && item.courseId === courseId;
    (byId || byCourse ? removed : kept).push(item);
  }
  const found = new Set(removed.map((item) => item.id.toUpperCase()));
  const missing = [...wanted].filter((id) => !found.has(id));
  if (removed.length > 0) writeJsonAtomic(file, kept);
  return { ok: true, removed, missing, all: kept };
}
