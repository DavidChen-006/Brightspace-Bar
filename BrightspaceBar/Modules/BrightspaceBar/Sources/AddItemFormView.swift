import AppKit
import CourseMenu

// ─────────────────────────────────────────────────────────────────────────────
// Intent 1: the inline add-an-item mini-form, hosted INSIDE the submenu.
//
// One of these per `AddItemKind` sits in every course's submenu, via the same
// `NSMenuItem.view` mechanism the course rows use. The subsection IS the kind:
// the heading says "Add quiz" and every draft this view emits is stamped with
// the kind (and course id) the model put in its `AddItemFormRow` — the student
// is never asked what kind of thing they are adding.
//
// SHIPPED PATH: inline fields, not the anchored-panel fallback. Text fields in
// a tracking menu are a supported-but-fussy AppKit shape (the Help menu's
// search field is the system's own precedent). Two things make editing work:
//
//   1. FIRST RESPONDER BY HAND. A menu's carrier window never becomes key, so
//      AppKit does not route focus for us. `MenuTextField.mouseDown` asks its
//      window directly for first-responder status, which a borderless carrier
//      window grants — the field editor then attaches and typing lands in the
//      field. (`needsPanelToBecomeKey` is the NSPanel version of the same
//      idea; menus need it done manually.)
//   2. NO KEY-EQUIVALENT AMBITIONS. While a field edits, the menu still sees
//      some keys first (arrow navigation is AppKit's); letters and paste reach
//      the field editor. That is acceptable for a name and a pasted link. If
//      live use shows focus NOT sticking on some macOS build, the documented
//      fallback is the `GraphDayPopup` panel recipe: clicking a field detaches
//      this same form into a small anchored borderless panel pre-scoped to the
//      kind. The seam for that swap is this one view.
//
// The due date is PICKED, never typed: an `NSDatePicker` in text-with-stepper
// style with `presentsCalendarOverlay` on, so clicking it drops the standard
// macOS calendar — a deterministic choice from a defined set — seeded to
// today 11:59 PM by `AddItemDefaults` (pure, tested policy, not view code).
// ─────────────────────────────────────────────────────────────────────────────

/// Layout numbers, one table like `ComponentMetrics` and for the same reason:
/// the frame arithmetic and `fittingSize` read the same values, so the form
/// cannot ask for a height its rows disagree with.
// `public` like `ComponentMetrics` and the hosting view, because the test
// target does a plain `import BrightspaceBar` (no `@testable`), matching the
// house rule that tests exercise the real public surface.
public enum AddItemFormMetrics {
    public static let headingHeight: CGFloat = 16
    public static let fieldHeight: CGFloat = 22
    public static let rowGap: CGFloat = 4
    public static let verticalPad: CGFloat = 6
    /// The picker row also holds the Add button, to its right.
    public static let addButtonWidth: CGFloat = 52
    public static let buttonGap: CGFloat = 6
    public static let width: CGFloat = 260

    /// heading + name + link + (picker/Add) rows, gapped and padded.
    public static var height: CGFloat {
        self.verticalPad * 2 + self.headingHeight + 3 * self.rowGap + 3 * self.fieldHeight
    }
}

/// A text field that can be edited inside a tracking menu: focus is requested
/// explicitly on click, because no window manager will do it for a menu's
/// never-key carrier window.
public final class MenuTextField: NSTextField {
    public override func mouseDown(with event: NSEvent) {
        self.window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // The system focus ring does not draw inside a menu's never-key carrier
    // window, so without help the only sign a field is editable is the caret —
    // easy to miss (user report, 2026-08-24: "I have to click around until I
    // see the blue blinker"). An accent border while editing is the visible
    // stand-in for the missing ring.
    public override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        self.setFocusedAppearance(true)
    }

    public override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        self.setFocusedAppearance(false)
    }

    private func setFocusedAppearance(_ focused: Bool) {
        self.wantsLayer = true
        self.layer?.borderWidth = focused ? 2 : 0
        self.layer?.borderColor = focused ? NSColor.controlAccentColor.cgColor : nil
        self.layer?.cornerRadius = focused ? 3 : 0
    }
}

/// The form: heading, name field, link field, date picker, Add. Emits one
/// `AddItemDraft` per successful Add and closes the menu, so the next open
/// renders the rebuilt model with the new item's square in the heatmap.
@MainActor
public final class AddItemFormView: NSView {
    private let form: AddItemFormRow
    private let onAdd: (@MainActor (AddItemDraft) -> Void)?

    public let nameField: MenuTextField
    public let linkField: MenuTextField
    public let datePicker: NSDatePicker

    public override var isFlipped: Bool { true }

    public init(form: AddItemFormRow, now: () -> Date, onAdd: (@MainActor (AddItemDraft) -> Void)?) {
        self.form = form
        self.onAdd = onAdd

        self.nameField = MenuTextField(string: "")
        self.linkField = MenuTextField(string: "")
        self.datePicker = NSDatePicker(frame: .zero)

        super.init(frame: CGRect(
            origin: .zero,
            size: CGSize(width: AddItemFormMetrics.width, height: AddItemFormMetrics.height)
        ))
        self.autoresizingMask = [.width]

        let inset = ComponentMetrics.textInset
        var y = AddItemFormMetrics.verticalPad

        // The heading — the row's identity, drawn like a native section header.
        let heading = NSTextField(labelWithString: form.kind.formHeading)
        heading.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        heading.frame = CGRect(
            x: inset, y: y,
            width: AddItemFormMetrics.width - inset * 2,
            height: AddItemFormMetrics.headingHeight
        )
        self.addSubview(heading)
        y += AddItemFormMetrics.headingHeight + AddItemFormMetrics.rowGap

        for (field, placeholder) in [
            (self.nameField, "Name"),
            (self.linkField, "Link (paste URL)"),
        ] {
            field.placeholderString = placeholder
            field.font = NSFont.menuFont(ofSize: 12)
            field.controlSize = .small
            field.lineBreakMode = .byTruncatingTail
            field.frame = CGRect(
                x: inset, y: y,
                width: AddItemFormMetrics.width - inset * 2,
                height: AddItemFormMetrics.fieldHeight
            )
            field.autoresizingMask = [.width]
            self.addSubview(field)
            y += AddItemFormMetrics.fieldHeight + AddItemFormMetrics.rowGap
        }

        // The due date, PICKED: stepper-style with the calendar overlay, so a
        // click drops the standard calendar rather than inviting typing.
        // Seeded from pure policy — today, 11:59 PM local.
        self.datePicker.datePickerStyle = .textFieldAndStepper
        self.datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        self.datePicker.presentsCalendarOverlay = true
        self.datePicker.controlSize = .small
        self.datePicker.font = NSFont.menuFont(ofSize: 12)
        self.datePicker.dateValue = AddItemDefaults.defaultDue(now: now(), timeZone: .current)
        self.datePicker.frame = CGRect(
            x: inset, y: y,
            width: AddItemFormMetrics.width - inset * 2
                - AddItemFormMetrics.addButtonWidth - AddItemFormMetrics.buttonGap,
            height: AddItemFormMetrics.fieldHeight
        )
        self.addSubview(self.datePicker)

        let add = NSButton(title: "Add", target: self, action: #selector(self.performAdd))
        add.bezelStyle = .rounded
        add.controlSize = .small
        add.frame = CGRect(
            x: AddItemFormMetrics.width - inset - AddItemFormMetrics.addButtonWidth,
            y: y,
            width: AddItemFormMetrics.addButtonWidth,
            height: AddItemFormMetrics.fieldHeight
        )
        add.autoresizingMask = [.minXMargin]
        self.addSubview(add)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("AddItemFormView is built in code, never from a nib")
    }

    /// A menu closes when a click lands on an item that has no view; a click
    /// inside this view must NOT bubble into item selection. Swallowing the
    /// event here keeps the menu open while the student fills the form.
    public override func mouseUp(with event: NSEvent) {}
    public override func mouseDown(with event: NSEvent) {}

    /// The one emission point. Both text fields must have content — a nameless
    /// or linkless item has nothing to render and nowhere to click — and the
    /// refusal is a beep rather than an alert, because an alert cannot be shown
    /// over a tracking menu.
    @objc public func performAdd() {
        // Commit any in-flight field editing so the value read is the value
        // typed, even when Add is clicked while a field still has focus.
        self.window?.makeFirstResponder(nil)
        let name = self.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = self.linkField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !link.isEmpty else {
            NSSound.beep()
            return
        }
        self.onAdd?(AddItemDraft(
            courseId: self.form.courseId,
            kind: self.form.kind,
            name: name,
            link: link,
            due: self.datePicker.dateValue
        ))
        self.nameField.stringValue = ""
        self.linkField.stringValue = ""
        // Close the whole menu: the model just changed, and the rebuilt menu —
        // new heatmap square included — is what the next open should show.
        self.enclosingMenuItem?.menu?.cancelTracking()
    }
}
