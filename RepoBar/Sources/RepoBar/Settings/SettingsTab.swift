import AppKit
import Foundation
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case display
    case repositories
    case accounts
    case notifications
    case advanced
    case about
    #if DEBUG
        case debug
    #endif

    static let defaultWidth: CGFloat = 540
    static let repositoriesWidth: CGFloat = 980
    /// Legacy default height retained for callers that still ask for "the" window height.
    /// Prefer `preferredHeight` per tab and `SettingsWindowSizing.clampedContentSize` to keep
    /// the window inside the screen's visible frame.
    static let windowHeight: CGFloat = 770
    /// Absolute minimum content size the Settings window should ever shrink to, regardless of tab.
    static let minimumContentSize = NSSize(width: 420, height: 360)

    var title: String {
        switch self {
        case .general: "General"
        case .display: "Display"
        case .repositories: "Repositories"
        case .accounts: "Accounts"
        case .notifications: "Notifications"
        case .advanced: "Advanced"
        case .about: "About"
        #if DEBUG
            case .debug: "Debug"
        #endif
        }
    }

    var preferredWidth: CGFloat {
        self == .repositories ? Self.repositoriesWidth : Self.defaultWidth
    }

    /// Per-tab ideal content height. Smaller tabs (e.g. About) get smaller windows so the
    /// window doesn't sit in the middle of the screen with a lot of dead space and a footer
    /// that can be hidden by the Dock on small displays.
    var preferredHeight: CGFloat {
        switch self {
        case .general: 540
        case .display: 540
        case .repositories: 660
        case .accounts: 620
        case .notifications: 540
        case .advanced: 600
        case .about: 560
        #if DEBUG
            case .debug: 540
        #endif
        }
    }
}
