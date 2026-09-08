/**
 * How the CLI talks: JSON when an agent asked for it, aligned text otherwise.
 * Pure functions from values to strings — the entry point decides which
 * stream they land on.
 */

/** Sorted, indented, newline-terminated: stable across runs, diffable, pipeable. */
export function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

/**
 * Rows of strings under a header, left-aligned in columns. No column wider
 * than its widest cell; a missing cell is blank. Widths are measured on the
 * text an agent will actually read, so wide unicode costs a little alignment
 * and nothing else.
 */
export function table(header, rows) {
  const all = [header, ...rows].map((row) => row.map((cell) => String(cell ?? "")));
  const widths = header.map((_, column) =>
    Math.max(...all.map((row) => (row[column] ?? "").length)),
  );
  const line = (row) =>
    row.map((cell, column) => cell.padEnd(widths[column])).join("  ").trimEnd();
  return `${all.map(line).join("\n")}\n`;
}

/**
 * The app's own short label — "CS 25200" out of `wl.202710.CS.25200.LE1` —
 * `MenuTranslation.subtitle(from:)` transcribed, so the CLI and the menu name
 * a course the same way. Null when the code is not that shape (the civics
 * test, a training module), and the caller falls back to the name.
 */
export function courseLabel(code) {
  const parts = String(code ?? "").split(".");
  if (parts.length < 5) return null;
  if (!/^\d{6}$/.test(parts[1])) return null;
  if (!/^\d+$/.test(parts[3])) return null;
  return `${parts[2]} ${parts[3]}`;
}

/** A due instant in the local zone, the way a person reads a calendar. */
export function localStamp(iso) {
  const at = new Date(iso ?? "");
  if (Number.isNaN(at.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return `${at.getFullYear()}-${pad(at.getMonth() + 1)}-${pad(at.getDate())} ${pad(at.getHours())}:${pad(at.getMinutes())}`;
}

/** "3 minutes ago" for a status line; never precise, never wrong by more than its unit. */
export function ageOf(iso, now) {
  const at = Date.parse(iso ?? "");
  if (Number.isNaN(at)) return "never";
  const seconds = Math.max(0, Math.round((now.getTime() - at) / 1000));
  if (seconds < 90) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 90) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 36) return `${hours} h ago`;
  return `${Math.round(hours / 24)} d ago`;
}
