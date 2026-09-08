/**
 * The pure readings of the content API, pinned on shapes recorded from the
 * live tenant (a ToC with nested modules, a Content-Disposition with the
 * RFC 5987 form, a grade-values row).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  filenameFrom, flattenToc, gradeRows, overviewText, syllabusCandidates,
} from "../src/agent/content.mjs";

const TOC = {
  Modules: [
    {
      ModuleId: 1, Title: "Official Course Syllabus with Assignments",
      Topics: [{ TopicId: 22438392, Title: "PHIL 219 Syllabus fall 2026", TypeIdentifier: "File", Url: "/content/enforced/x/PHIL 219 Syllabus fall 2026.docx" }],
      Modules: [],
    },
    {
      ModuleId: 2, Title: "Topic 1",
      Topics: [],
      Modules: [{
        ModuleId: 3, Title: "Slides!",
        Topics: [
          { TopicId: 10, Title: "Slides! 1a", TypeIdentifier: "Link", Url: "https://docs.google.com/presentation/d/abc" },
          { TopicId: 11, Title: "Recording 1a!", TypeIdentifier: "File", Url: "/content/enforced/x/Recording 1a!.mp4", IsHidden: true, EndDateTime: "2026-10-01T03:59:00.000Z" },
        ],
      }],
    },
  ],
};

test("flattenToc walks depth-first in course order and carries the module path", () => {
  const rows = flattenToc(TOC);
  assert.deepEqual(rows.map((r) => [r.topicId, r.type, r.module]), [
    [22438392, "File", "Official Course Syllabus with Assignments"],
    [10, "Link", "Topic 1 / Slides!"],
    [11, "File", "Topic 1 / Slides!"],
  ]);
  assert.equal(rows[1].url, "https://docs.google.com/presentation/d/abc");
  assert.equal(rows[2].isHidden, true);
  assert.equal(rows[2].dueDate, "2026-10-01T03:59:00.000Z");
  assert.equal(rows[0].isHidden, false);
});

test("flattenToc tolerates an empty or malformed answer", () => {
  assert.deepEqual(flattenToc(null), []);
  assert.deepEqual(flattenToc({}), []);
  assert.deepEqual(flattenToc({ Modules: [{ Title: "x" }] }), []);
});

test("syllabusCandidates keys on the title, or on a syllabus module for files", () => {
  const rows = flattenToc(TOC);
  assert.deepEqual(syllabusCandidates(rows).map((r) => r.topicId), [22438392]);
  const byModule = [{ topicId: 5, title: "Fall 2026.pdf", type: "File", module: "Course Syllabus" }];
  assert.deepEqual(syllabusCandidates(byModule).map((r) => r.topicId), [5]);
  const linkInModule = [{ topicId: 6, title: "Slides", type: "Link", module: "Syllabus" }];
  assert.deepEqual(syllabusCandidates(linkInModule), []);
});

test("filenameFrom prefers the RFC 5987 name, then the plain one, then the fallback", () => {
  assert.equal(filenameFrom("attachment; filename*=UTF-8''week1.txt; filename=\"week1.txt\"", "x"), "week1.txt");
  assert.equal(filenameFrom("attachment; filename*=UTF-8''PHIL%20219%20Syllabus.docx", "x"), "PHIL 219 Syllabus.docx");
  assert.equal(filenameFrom("attachment; filename=\"a b.pdf\"", "x"), "a b.pdf");
  assert.equal(filenameFrom("attachment; filename=plain.pdf", "x"), "plain.pdf");
  assert.equal(filenameFrom(null, "topic-9"), "topic-9");
  assert.equal(filenameFrom("attachment", "topic-9"), "topic-9");
});

test("filenameFrom cannot be steered into another directory", () => {
  assert.equal(filenameFrom("attachment; filename=\"../../etc/passwd\"", "x"), "passwd");
  assert.equal(filenameFrom("attachment; filename=\"..\\\\..\\\\evil.exe\"", "x"), "evil.exe");
  assert.equal(filenameFrom("attachment; filename*=UTF-8''..%2F..%2Fevil.sh", "x"), "evil.sh");
  assert.equal(filenameFrom("attachment; filename=\".hidden\"", "x"), "hidden");
  assert.equal(filenameFrom("attachment; filename=\"...\"", "topic-9"), "topic-9");
  assert.equal(filenameFrom("attachment; filename=\"a/\"", "topic-9"), "topic-9");
});

test("overviewText is the trimmed text, or empty", () => {
  assert.equal(overviewText({ Description: { Text: "  CS 211 \n" } }), "CS 211");
  assert.equal(overviewText({ Description: { Text: "" } }), "");
  assert.equal(overviewText(null), "");
});

test("gradeRows keeps what the grades page shows", () => {
  const rows = gradeRows([
    { GradeObjectIdentifier: "1", GradeObjectName: "Lab 1", GradeObjectTypeName: "Numeric", DisplayedGrade: "9 / 10", PointsNumerator: 9, PointsDenominator: 10, LastModified: "2026-09-01T00:00:00.000Z" },
    { GradeObjectIdentifier: "2", GradeObjectName: "Participation ID", GradeObjectTypeName: "Text", DisplayedGrade: "401" },
  ]);
  assert.deepEqual(rows, [
    { id: "1", name: "Lab 1", type: "Numeric", grade: "9 / 10", points: "9/10", lastModified: "2026-09-01T00:00:00.000Z" },
    { id: "2", name: "Participation ID", type: "Text", grade: "401", points: "", lastModified: null },
  ]);
  assert.deepEqual(gradeRows(null), []);
});
