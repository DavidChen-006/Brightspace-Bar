import AppKit
import Foundation
import Testing

import BrightspaceBar
import CourseMenu

// ═════════════════════════════════════════════════════════════════════════════
// The add-item mini-form (Intent 1) — the GUI half, headless.
//
// PRIORITIES (the 1–2 carrying 80% of the value):
//
//   1. THE DRAFT SAYS WHAT THE FORM SAYS. The kind and course id come from the
//      model's `AddItemFormRow`, never from anything typed — the subsection IS
//      the kind — and the name/link travel trimmed but otherwise verbatim. A
//      transposed course id here files David's exam under someone else's
//      class, silently.
//
//   2. NO EMPTY ITEMS. An item with no name or no link renders a row that says
//      nothing or clicks nowhere; the form is the one gate (the store's own
//      guard is the backstop for the link only).
//
// CULLED: focus behaviour inside a live tracking menu — first-responder
// routing needs a real UI session and a real menu, so it is hand-verified
// (see AddItemFormView's header); what is pinned here is everything that
// does not need one.
//
// SCOPE: all small. In-process AppKit object graphs; no menu is ever tracked.
// ═════════════════════════════════════════════════════════════════════════════

/// 10:00 Tue Feb 10 2026 in Indiana — the pinned Tuesday every graph suite uses.
private let pinnedNow = Date(timeIntervalSince1970: 1_770_735_600)

@MainActor
private func makeForm(
    courseId: Int = 1_360_027,
    kind: AddItemKind = .quiz,
    onAdd: (@MainActor (AddItemDraft) -> Void)? = nil
) -> AddItemFormView {
    AddItemFormView(
        form: AddItemFormRow(courseId: courseId, kind: kind),
        now: { pinnedNow },
        onAdd: onAdd
    )
}

@Suite("AddItemFormView — drafts, defaults, and the gate")
@MainActor
struct AddItemFormTests {

    // ── Priority 1: the draft says what the form says ────────────────────────

    @Test("Add emits a draft carrying the form's course and kind, verbatim fields")
    func addEmitsTheDraft() {
        // Arrange
        var drafts: [AddItemDraft] = []
        let form = makeForm(courseId: 445_296, kind: .test) { drafts.append($0) }
        form.nameField.stringValue = "Exam 1"
        form.linkField.stringValue = "https://example.org/study-guide"
        let picked = Date(timeIntervalSince1970: 1_771_000_000)
        form.datePicker.dateValue = picked

        // Act
        form.performAdd()

        // Assert — one draft, every field the form's own.
        #expect(drafts == [AddItemDraft(
            courseId: 445_296, kind: .test,
            name: "Exam 1", link: "https://example.org/study-guide", due: picked
        )])
        // And the text fields reset for the next entry; the picker keeps its
        // value (re-seeded on the next menu build anyway).
        #expect(form.nameField.stringValue.isEmpty)
        #expect(form.linkField.stringValue.isEmpty)
    }

    @Test("name and link are trimmed, not rewritten")
    func fieldsAreTrimmedOnly() {
        // Arrange — whitespace from a sloppy paste; the inner text must survive
        // untouched (the link is opaque by contract).
        var drafts: [AddItemDraft] = []
        let form = makeForm { drafts.append($0) }
        form.nameField.stringValue = "  Quiz 4 \n"
        form.linkField.stringValue = " see syllabus §3 "

        // Act
        form.performAdd()

        // Assert
        #expect(drafts.map(\.name) == ["Quiz 4"])
        #expect(drafts.map(\.link) == ["see syllabus §3"])
    }

    // ── Priority 2: no empty items ───────────────────────────────────────────

    @Test("a blank name or a blank link emits nothing", arguments: [
        ("", "https://example.org"),
        ("Exam 1", ""),
        ("   ", "https://example.org"),
        ("Exam 1", " \n"),
    ])
    func blanksAreRefused(name: String, link: String) {
        // Arrange
        var drafts: [AddItemDraft] = []
        let form = makeForm { drafts.append($0) }
        form.nameField.stringValue = name
        form.linkField.stringValue = link

        // Act
        form.performAdd()

        // Assert — refused at the gate; the typed content is NOT cleared, so
        // the student can finish rather than retype.
        #expect(drafts.isEmpty)
        #expect(form.nameField.stringValue == name)
        #expect(form.linkField.stringValue == link)
    }

    // ── The picked-not-typed decision, pinned on the control itself ──────────

    @Test("the due date control is a calendar-overlay picker seeded to 11:59 PM")
    func pickerIsConfiguredForPickingNotTyping() {
        // Arrange / Act
        let form = makeForm()

        // Assert — the style + overlay pair is what makes a click drop the
        // standard macOS calendar (deterministic, chosen from a defined set),
        // and the seed is the pure default policy in the current zone.
        #expect(form.datePicker.datePickerStyle == .textFieldAndStepper)
        #expect(form.datePicker.presentsCalendarOverlay)
        #expect(form.datePicker.datePickerElements == [.yearMonthDay, .hourMinute])
        #expect(form.datePicker.dateValue
            == AddItemDefaults.defaultDue(now: pinnedNow, timeZone: .current))
    }
}

@Suite("MenuAssembler — the add-form rows")
@MainActor
struct MenuAssemblerAddFormTests {

    private func assemble(_ model: MenuModel) -> NSMenu {
        MenuAssembler(opener: FakeURLOpener(), now: { pinnedNow }, onCommand: { _ in })
            .assemble(model)
    }

    @Test("a course submenu hosts one form view per addForm row, after the home row")
    func addFormsAreHostedViews() throws {
        // Arrange — the shape `MenuTranslation` emits since Intent 1.
        let course = CourseRow(
            id: 445_296, title: "Systems Programming", subtitle: "CS 25200",
            url: URL(string: "https://purdue.brightspace.com/d2l/home/445296")!,
            submenu: AddItemKind.allCases.map {
                .addForm(AddItemFormRow(courseId: 445_296, kind: $0))
            }
        )

        // Act
        let menu = self.assemble(MenuModel(rows: [.course(course)]))
        let submenu = try #require(menu.items.first?.submenu)

        // Assert — [home, separator, three hosted forms], titled by heading so
        // accessibility and this suite can find what the view draws.
        try #require(submenu.items.count == 5)
        #expect(submenu.items[0].title == "Open Course Home")
        #expect(submenu.items[1].isSeparatorItem)
        for (index, kind) in AddItemKind.allCases.enumerated() {
            let item = submenu.items[index + 2]
            #expect(item.title == kind.formHeading)
            #expect(item.view is AddItemFormView)
            // No action: the view owns every interaction, so a stray Enter on
            // the highlighted row must not fire anything.
            #expect(item.action == nil)
        }
    }
}
