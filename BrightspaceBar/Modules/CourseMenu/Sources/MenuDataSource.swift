import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// THE BEHAVIOURAL HALF OF THE CONTRACT. Frozen.
//
// Two methods, and the split between them is the design:
//
//   currentMenu()  — cheap, never touches the network. This is what a menu-open
//                    draws from, so the dropdown appears instantly.
//   refresh()      — may do I/O. Returns the menu after the attempt.
//
// A GUI that calls only `currentMenu()` on open and `refresh()` in the background
// can never block the menu on a network round trip. That property is why these are
// two methods rather than one.
// ─────────────────────────────────────────────────────────────────────────────

public protocol MenuDataSource: Sendable {
    /// Whatever is already known, served immediately from memory or disk.
    /// Must not block on the network.
    func currentMenu() async -> MenuModel

    /// Ask for fresher data, then return the resulting menu.
    ///
    /// Deliberately non-throwing: a failed refresh is not an error the GUI should
    /// handle with a `catch`. The backend already preserves the last good data on
    /// failure, so the right behaviour is to return the still-valid previous menu —
    /// optionally with a `.status` or `.message` row explaining the staleness.
    func refresh() async -> MenuModel
}
