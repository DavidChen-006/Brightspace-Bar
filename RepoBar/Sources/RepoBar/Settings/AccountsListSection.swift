import Foundation
import RepoBarCore
import SwiftUI

/// Read-write list of configured accounts with select/remove/refresh controls.
///
/// Renders one row per `session.settings.accounts` entry plus a footer
/// describing how to add more accounts (the existing "Account" section below
/// always adds a new account rather than replacing the active one).
struct AccountsListSection: View {
    @Bindable var session: Session
    let appState: AppState

    var body: some View {
        Section {
            if self.session.settings.accounts.isEmpty {
                Text("No accounts configured yet. Sign in below to add your first account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(self.session.settings.accounts) { account in
                    self.row(for: account)
                    if account.id != self.session.settings.accounts.last?.id {
                        Divider()
                    }
                }
            }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Sign in below to add additional accounts. The active account is used for CLI commands and the default for menu actions.")
        }
    }

    private func row(for account: Account) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.id == self.session.settings.activeAccountID ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(account.id == self.session.settings.activeAccountID ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.usernameAtHost)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(account.authMethod.label)
                    Text("•")
                    Text(account.host.host ?? "github.com")
                    if account.id == self.session.settings.activeAccountID {
                        Text("•")
                        Text("active")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Button("Use") {
                Task { await self.appState.switchActiveAccount(to: account.id) }
            }
            .controlSize(.small)
            .disabled(account.id == self.session.settings.activeAccountID)

            Button("Check") {
                Task { await self.checkToken(for: account.id) }
            }
            .controlSize(.small)

            Button(role: .destructive) {
                Task { await self.appState.removeAccount(account.id) }
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Remove account")
        }
        .padding(.vertical, 6)
    }

    private func checkToken(for accountID: String) async {
        guard let client = self.appState.accountManager.client(for: accountID) else { return }

        _ = try? await client.currentUser()
    }
}
