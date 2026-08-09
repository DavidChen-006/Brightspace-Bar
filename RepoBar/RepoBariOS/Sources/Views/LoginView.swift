import SwiftUI

struct LoginView: View {
    @Bindable var appModel: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 40)

            VStack(spacing: 18) {
                Image("RepoBarLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: Color.black.opacity(0.22), radius: 16, x: 0, y: 10)
                    .accessibilityHidden(true)
                Text("RepoBar")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("Your repos, everywhere.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if let error = appModel.session.lastError {
                GlassCard {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            VStack(spacing: 12) {
                if appModel.session.account == .loggingIn {
                    ProgressView("Signing in…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    Button {
                        Task { await appModel.login() }
                    } label: {
                        Label("Sign in with GitHub", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .font(.headline)
                    .buttonStyle(.borderedProminent)
                }

                Button("Settings") {
                    showSettings = true
                }
                .buttonStyle(.plain)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(appModel: appModel, showsCloseButton: true)
            }
        }
    }
}
