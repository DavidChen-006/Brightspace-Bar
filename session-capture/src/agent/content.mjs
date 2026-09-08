/**
 * Pure readings of what the content API answers — no I/O, so the shapes are
 * pinned without a tenant. The routes themselves are documented for the
 * agent in the skill (skills/brightspace-bar/references/endpoints.md).
 */

/**
 * `GET le:{ou}/content/toc` → one flat list, depth-first in the order the
 * course shows it. Every row carries the module path it sits under, so an
 * agent can tell "Syllabus" under "Course Information" from a lecture slide
 * of the same name without walking a tree.
 *
 * `type` is D2L's `TypeIdentifier` (File, Link, ContentService, …) and `url`
 * is what D2L gave — relative for a File (the `fetch` command downloads it
 * through the API route by topic id), absolute for a Link.
 */
export function flattenToc(toc) {
  const rows = [];
  const walk = (modules, path) => {
    for (const module of modules ?? []) {
      const here = [...path, module.Title ?? ""];
      for (const topic of module.Topics ?? []) {
        rows.push({
          topicId: topic.TopicId,
          title: topic.Title ?? "",
          type: topic.TypeIdentifier ?? "",
          module: here.join(" / "),
          url: topic.Url ?? null,
          dueDate: topic.EndDateTime ?? null,
          isHidden: topic.IsHidden === true,
        });
      }
      walk(module.Modules, here);
    }
  };
  walk(toc?.Modules, []);
  return rows;
}

/** Topics whose title says syllabus — the file the whole agent surface exists to read. */
export function syllabusCandidates(rows) {
  return rows.filter((row) => /syllab/i.test(row.title) || /syllab/i.test(row.module) && row.type === "File");
}

/**
 * The filename a download should land as: the server's own, from
 * `Content-Disposition` (RFC 5987 `filename*=` first, then `filename=`),
 * else a fallback the caller names. Path separators are stripped so a
 * server cannot name a file into another directory.
 */
export function filenameFrom(disposition, fallback) {
  const header = String(disposition ?? "");
  const star = /filename\*\s*=\s*(?:UTF-8|utf-8)''([^;]+)/.exec(header);
  let name = null;
  if (star) {
    try {
      name = decodeURIComponent(star[1].trim());
    } catch {
      name = star[1].trim();
    }
  } else {
    const plain = /filename\s*=\s*"?([^";]+)"?/.exec(header);
    if (plain) name = plain[1].trim();
  }
  // Only the last path component survives, and it cannot start with a dot:
  // a server cannot name a file into another directory, or hide one.
  const last = (name ?? fallback).replace(/\\/g, "/").split("/").pop() ?? "";
  const safe = last.replace(/^\.+/, "").trim();
  return safe || fallback;
}

/** `GET le:{ou}/overview` → the text a student sees, or "" when there is none. */
export function overviewText(overview) {
  const text = overview?.Description?.Text;
  return typeof text === "string" ? text.trim() : "";
}

/**
 * `GET le:{ou}/grades/values/myGradeValues/` → rows an agent can read aloud.
 * Only what a student sees on their own grades page: the name, the displayed
 * grade, and the points when the column has them.
 */
export function gradeRows(values) {
  if (!Array.isArray(values)) return [];
  return values.map((value) => ({
    id: value.GradeObjectIdentifier ?? null,
    name: value.GradeObjectName ?? "",
    type: value.GradeObjectTypeName ?? "",
    grade: value.DisplayedGrade ?? "",
    points: typeof value.PointsNumerator === "number" && typeof value.PointsDenominator === "number"
      ? `${value.PointsNumerator}/${value.PointsDenominator}`
      : "",
    lastModified: value.LastModified ?? null,
  }));
}
