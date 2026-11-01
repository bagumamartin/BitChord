import SwiftUI
#if os(iOS)
import UIKit
#endif
import BitChordShared

/// Account & Settings hub — Apple-style modal account sheet and profile switcher.
///
/// Combines the active identity card, YouTube channel/profile switcher,
/// seamless inline push into Settings, and account actions (Add Account, Sign Out).
struct AccountProfileSheet: View {
    @Environment(AuthController.self) private var auth
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @Environment(\.dismiss) private var dismiss

    @State private var showingSignOutConfirm = false

    /// The account this sheet is showing, or nil for "whichever is selected".
    let scopedAccountId: String?

    init(scopedAccountId: String? = nil) {
        self.scopedAccountId = scopedAccountId
    }

    private var accounts: [AccountSummary] {
        auth.accounts
    }

    var body: some View {
        NavigationStack {
            List {
                // MARK: - Active Account Card / Sign In
                Section {
                    if auth.signedIn {
                        activeAccountCard
                    } else {
                        signedOutCard
                    }
                }

                // MARK: - Channels / Profiles Switcher
                if auth.signedIn {
                    ForEach(accounts) { account in
                        if !account.profiles.isEmpty {
                            Section {
                                ForEach(account.profiles) { profile in
                                    profileRow(account: account, profile: profile)
                                }
                            } header: {
                                if accounts.count > 1 {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(account.displayName)
                                        if !account.email.isEmpty {
                                            Text(account.email)
                                                .font(.caption)
                                                .textCase(nil)
                                        }
                                    }
                                } else {
                                    Text("Channels")
                                }
                            }
                        }
                    }
                }

                // MARK: - Settings Drill-Down
                Section {
                    Button {
                        dismiss()
                        #if os(macOS)
                        openSettings()
                        #else
                        appModel.settingsPresented = true
                        #endif
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.gray.opacity(0.18))
                                    .frame(width: 32, height: 32)
                                Image(systemName: "gearshape.fill")
                                    .scaledFont(size: 16, weight: .medium)
                                    .foregroundStyle(.primary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Settings")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("Audio quality, playback, appearance")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // MARK: - Account Actions
                if auth.signedIn {
                    Section {
                        Button {
                            dismiss()
                            Task { @MainActor in auth.loginPresented = true }
                        } label: {
                            Label("Add Another Account", systemImage: "person.badge.plus")
                                .foregroundStyle(Color.accentColor)
                        }

                        Button(role: .destructive) {
                            showingSignOutConfirm = true
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #else
            .listStyle(.inset)
            #endif
            .navigationTitle("Account")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(
                "Sign Out",
                isPresented: $showingSignOutConfirm,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    auth.signOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Signing out removes the shared session from iCloud Keychain. Devices that already adopted it may remain signed in.")
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: - Subviews

    @ViewBuilder
    private var activeAccountCard: some View {
        HStack(spacing: 16) {
            Avatar(
                url: auth.accountPhotoUrl,
                name: auth.accountName ?? "Account",
                side: 54
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(auth.accountName ?? (auth.listeningAs?.displayName ?? "Signed In"))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                if let email = auth.accountEmail, !email.isEmpty {
                    Text(email)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if let handle = auth.listeningAs?.activeProfile?.handle, !handle.isEmpty {
                    Text(handle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Text("YouTube Music")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                    if let profileName = auth.listeningAs?.activeProfile?.name,
                       profileName != auth.accountName {
                        Text("•")
                            .scaledFont(size: 10)
                            .foregroundStyle(.secondary)
                        Text(profileName)
                            .scaledFont(size: 11, weight: .regular)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.clear)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75)
                    Image(systemName: "person.fill")
                        .scaledFont(size: 22, weight: .medium)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 50, height: 50)
                .chromeGlass(in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Sign In to YouTube Music")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Access your playlists, library, and personalized mixes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                dismiss()
                Task { @MainActor in auth.loginPresented = true }
            } label: {
                HStack {
                    Spacer()
                    Text("Sign In")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func profileRow(account: AccountSummary, profile: AccountProfile) -> some View {
        let isSelected = auth.listeningAs?.id == account.id
            && auth.listeningAs?.activeProfileId == profile.id

        return Button {
            auth.select(accountId: account.id, profileId: profile.id)
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 12) {
                Avatar(url: profile.avatar, name: profile.name, side: 38)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    if !profile.handle.isEmpty {
                        Text(profile.handle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .scaledFont(size: 14, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Listening as this channel")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The upstream account affordance at the right end of the top bar.
///
/// Designed as a pure 34pt glass circle (matching upstream `AVATAR_SIZE = 34.dp`)
/// with no outer rectangular bounding box, ensuring native iOS navigation bar
/// chrome treats the circle itself as the glass element.
struct TopBarAccountButton: View {
    @Environment(AuthController.self) private var auth
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var showingProfiles = false

    var body: some View {
        Button {
            showingProfiles = true
        } label: {
            profileCircle
        }
        .buttonStyle(ProfileCircleButtonStyle())
        .accessibilityLabel(auth.signedIn ? "Account and Settings" : "Sign In and Settings")
        .contextMenu {
            if auth.signedIn {
                Button {
                    showingProfiles = true
                } label: {
                    Label("Account & Settings", systemImage: "person.crop.circle")
                }

                if let currentAccount = auth.listeningAs, currentAccount.profiles.count > 1 {
                    Menu {
                        ForEach(currentAccount.profiles) { profile in
                            Button {
                                auth.select(accountId: currentAccount.id, profileId: profile.id)
                            } label: {
                                if auth.listeningAs?.activeProfileId == profile.id {
                                    Label(profile.name, systemImage: "checkmark")
                                } else {
                                    Text(profile.name)
                                }
                            }
                        }
                    } label: {
                        Label("Switch Channel", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Button {
                    auth.loginPresented = true
                } label: {
                    Label("Add Another Account", systemImage: "person.badge.plus")
                }

                Divider()

                Button(role: .destructive) {
                    auth.signOut()
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    auth.loginPresented = true
                } label: {
                    Label("Sign In", systemImage: "person.crop.circle.badge.plus")
                }

                Button {
                    #if os(macOS)
                    openSettings()
                    #else
                    appModel.settingsPresented = true
                    #endif
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard auth.signedIn,
                          abs(value.translation.height) > abs(value.translation.width)
                    else { return }
                    auth.stepProfile(forward: value.translation.height > 0)
                }
        )
        .sheet(isPresented: $showingProfiles) {
            AccountProfileSheet(scopedAccountId: auth.listeningAs?.id)
                .environment(controller)
                .environment(appModel)
                .environment(auth)
        }
    }

    @ViewBuilder
    private var profileCircle: some View {
        if auth.signedIn, let photoUrl = auth.accountPhotoUrl {
            Avatar(
                url: photoUrl,
                name: auth.accountName ?? "Account",
                side: 34
            )
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6)
            )
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)
        } else if auth.signedIn, let name = auth.accountName, !name.isEmpty {
            Avatar(
                url: nil,
                name: name,
                side: 34
            )
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6)
            )
            .contentShape(Circle())
        } else {
            // Pure glass circle — "the glass thing itself"
            ZStack {
                Circle()
                    .fill(.clear)
                Circle()
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                Image(systemName: "person.fill")
                    .scaledFont(size: 14, weight: .semibold)
                    .foregroundStyle(.primary.opacity(0.65))
            }
            .frame(width: 34, height: 34)
            .chromeGlass(in: Circle())
            .clipShape(Circle())
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
        }
    }
}

/// Custom button style for the top bar profile circle that prevents iOS toolbar
/// from wrapping the button in a rectangular or pill glass chrome, providing
/// smooth interactive spring feedback on press.
struct ProfileCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// An account's avatar, which opens the selector and steps between identities on
/// a swipe. The compact control upstream puts on every visible account avatar.
struct AccountAvatarButton: View {
    @Environment(AuthController.self) private var auth
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var appModel
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var showingSheet = false

    private var profile: AccountProfile? { auth.listeningAs?.activeProfile }

    var body: some View {
        Button {
            showingSheet = true
        } label: {
            Avatar(url: profile?.avatar, name: profile?.name ?? "Account", side: 34)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .scaledFont(size: 11, weight: .semibold)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .offset(x: 2, y: 2)
                }
        }
        .buttonStyle(.plain)
        .disabled(!auth.signedIn || auth.listeningAs == nil)
        .opacity(auth.signedIn && auth.listeningAs != nil ? 1 : 0.4)
        .accessibilityLabel(auth.listeningAs.map { "Listening as \($0.activeProfile?.name ?? $0.displayName)" } ?? "Not signed in")
        .accessibilityHint("Choose which YouTube channel to listen as")
        .sheet(isPresented: $showingSheet) {
            AccountProfileSheet(scopedAccountId: auth.listeningAs?.id)
                .environment(controller)
                .environment(appModel)
                .environment(auth)
        }
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    auth.stepProfile(forward: value.translation.width < 0)
                }
        )
    }
}

/// A round image that falls back to a monogram, on a chrome backing.
struct Avatar: View {
    let url: String?
    let name: String
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)

            Group {
                if let url, let address = URL(string: url) {
                    AsyncImage(url: address) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            monogram
                        }
                    }
                } else {
                    monogram
                }
            }
        }
        .frame(width: side, height: side)
        .chromeGlass(in: Circle())
        .clipShape(Circle())
    }

    private var monogram: some View {
        Text(name.trimmingCharacters(in: .whitespaces).prefix(1).uppercased())
            .scaledFont(size: side * 0.42, weight: .semibold)
            .foregroundStyle(.white.opacity(0.9))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.14))
    }
}

#if os(iOS)
/// A page's leading top-bar items: the BitChord mark and, on the iPad, back and
/// forward through the tab's pages, beside it as the Mac's titlebar has them.
struct TopBarLeadingItems: ToolbarContent {
    @Environment(\.pageHistory) private var history

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { TopBarLeadingMark() }
        if let history {
            if #available(iOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
            }
            ToolbarItem(placement: .topBarLeading) { PageHistoryButtons(navigator: history) }
        }
    }
}

/// Back and forward through one tab's pages.
struct PageHistoryButtons: View {
    let navigator: PathNavigator

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.left", "Back", key: "[", enabled: navigator.canGoBack) { navigator.goBack() }
            button("chevron.right", "Forward", key: "]", enabled: navigator.canGoForward) { navigator.goForward() }
        }
    }

    private func button(
        _ symbol: String, _ label: LocalizedStringKey, key: KeyEquivalent,
        enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(size: 17, weight: .semibold)
                .frame(width: 36, height: 34)
                .contentShape(.rect)
        }
        .buttonStyle(ProfileCircleButtonStyle())
        .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.3))
        .disabled(!enabled)
        .keyboardShortcut(key, modifiers: .command)
        .accessibilityLabel(label)
    }
}
#endif

/// Root-page brand mark: upstream FrostedTopBar's leading BitChord logo,
/// sized and positioned for native Apple navigation bars across all primary tabs.
struct TopBarLeadingMark: View {
    var body: some View {
        Image(.bchLogo)
            .resizable()
            .scaledToFit()
            .frame(width: 28, height: 18)
            .accessibilityHidden(true)
    }
}
