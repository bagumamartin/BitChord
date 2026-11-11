#if os(macOS)
import SwiftUI
import AppKit
import BitChordShared

/// Stable identifiers for the window toolbar's own controls, so toolbar
/// customisation and SwiftUI's own diffing keep track of them.
enum MacToolbarItemID {
    static let searchAction = "bitchord.searchAction"
    static let searchField = "bitchord.searchField"
    static let searchSource = "bitchord.searchSource"
    static let account = "bitchord.account"
    static let downloads = "bitchord.downloads"
}

/// Which panel is open beside the library.
///
/// Lyrics and the queue used to be destinations *inside* the full player, which
/// on the Mac meant the whole window. Music keeps them in a trailing inspector
/// so the library stays where it is while you read the lyrics — this is that
/// panel, and the player keeps them too for when it is open.
enum MacInspectorKind: String, Identifiable {
    case lyrics
    case queue

    var id: String { rawValue }

    var label: String {
        self == .lyrics ? "Lyrics" : "Queue"
    }
}

extension EnvironmentValues {
    /// The inspector the pill's lyrics and queue buttons open and close.
    @Entry var macInspectorSelection: Binding<MacInspectorKind?> = .constant(nil)
    /// The main window's account sheet, owned by `MacWindowAccountToolbar`.
    @Entry var macAccountSheet: Binding<Bool> = .constant(false)
}

/// The main window's trailing controls: account, then Downloads.
struct MacWindowControls: ToolbarContent {
    var includesSearchAction = true

    var body: some ToolbarContent {
        if includesSearchAction {
            ToolbarItem(id: MacToolbarItemID.searchAction, placement: .primaryAction) {
                TopBarSearchButton()
            }
        }
        ToolbarItem(id: MacToolbarItemID.account, placement: .primaryAction) {
            MacAccountToolbarButton()
        }
        ToolbarItem(id: MacToolbarItemID.downloads, placement: .primaryAction) {
            MacDownloadsButton()
        }
    }
}

/// The floating pill under a page in the browse stack. Each page carries it,
/// the root and every pushed one: an inset on the stack itself reaches only
/// its root page.
struct MacPillInset: ViewModifier {
    @State private var windowWidth: CGFloat = 0

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            // Only a window that is actually narrow gets the icon bar over the
            // pill. Keying it off a collapsed sidebar too put an iPhone-style
            // tab bar on top of the pill in a full-width window, and the
            // window's width reads 0 until AppKit reports it, which flashed
            // the bar on every page's first frame. A collapsed sidebar is one
            // click on the toolbar's sidebar button away.
            let compact = windowWidth > 0 && windowWidth < 900
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: compact ? 8 : 0) {
                    if compact {
                        MacCompactNavigationBar()
                    }
                    PlaybackPill()
                        .frame(maxWidth: compact ? 620 : 940)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity)
                }
                .frame(height: compact ? 112 : 88, alignment: .bottom)
            }
            .background(WindowWidthReader { windowWidth = $0 }.frame(width: 0, height: 0))
        }
    }
}

/// Sidebar destinations stay reachable after the split view becomes too narrow
/// to show its leading column. The playback pill remains directly below them.
private struct MacCompactNavigationBar: View {
    @Environment(AppModel.self) private var appModel
    @SceneStorage("bitchord.selectedTab") private var selectedTab = AppModel.Tab.home.rawValue

    private let tabs: [(AppModel.Tab, String, String)] = [
        (.home, "Home", "house"),
        (.explore, "Explore", "safari"),
        (.library, "Library", "music.note.list"),
        (.search, "Search", "magnifyingglass")
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs.indices, id: \.self) { index in
                let (tab, title, symbol) = tabs[index]
                Button {
                    appModel.requestedTab = tab
                } label: {
                    Label(title, systemImage: symbol)
                        .labelStyle(.iconOnly)
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .contentShape(Capsule())
                        .foregroundStyle(selectedTab == tab.rawValue ? Color.accentColor : Color.primary)
                        .background {
                            if selectedTab == tab.rawValue { Capsule().fill(Color.accentColor.opacity(0.12)) }
                        }
                }
                .buttonStyle(.plain)
                .help(title)
                .accessibilityLabel(title)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: 260)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 1))
    }
}

private struct WindowWidthReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReaderView)?.onChange = onChange
        (nsView as? ReaderView)?.reportWidth()
    }

    private final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var resizeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            resizeObserver = window.map { observedWindow in
                NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: observedWindow, queue: .main) { [weak self] _ in
                    self?.reportWidth()
                }
            }
            reportWidth()
        }

        func reportWidth() { onChange?(window?.frame.width ?? 0) }
    }
}

/// Account and profile switching is a first-class toolbar destination on Mac,
/// matching the account control used by the other Apple shells.
private struct MacAccountToolbarButton: View {
    @Environment(AuthController.self) private var auth
    @Environment(\.macAccountSheet) private var isPresented

    var body: some View {
        Menu {
            Button(auth.signedIn ? "Account and Profiles" : "Sign In", systemImage: "person.crop.circle") {
                isPresented.wrappedValue = true
            }
        } label: {
            Group {
                if auth.signedIn, let photo = auth.accountPhotoUrl {
                    Avatar(url: photo, name: auth.accountName ?? "Account", side: 24)
                        .clipShape(Circle())
                } else if auth.signedIn, let name = auth.accountName, !name.isEmpty {
                    Avatar(url: nil, name: name, side: 24)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.title3)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .help(auth.signedIn ? "Account and profiles" : "Sign in")
        .accessibilityLabel(auth.signedIn ? "Account and profiles" : "Sign in")
    }
}

struct MacWindowAccountToolbar: ViewModifier {
    @State private var presentsAccount = false

    func body(content: Content) -> some View {
        // The button itself is in `MacWindowControls`; this owns its sheet.
        content
            .environment(\.macAccountSheet, $presentsAccount)
            .sheet(isPresented: $presentsAccount) {
                AccountProfileSheet().frame(minWidth: 420, minHeight: 520)
            }
    }
}

// MARK: - Window geometry

/// Reports a view's distance from its window's left edge: when it joins the
/// window and when the window enters or leaves full screen, the only events
/// that move a titlebar item next to the traffic lights. Toolbar items are
/// hosted separately, so SwiftUI's own coordinate spaces cannot compare them.
struct WindowLeadingReader: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            guard let window else { return }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
            report()
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        /// Read after the titlebar has laid out the new arrangement.
        private func report() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onChange?(self.convert(self.bounds, to: nil).minX)
            }
        }
    }
}

// MARK: - Settings window

/// Puts its window's toolbar in the unified style: one titlebar row holding
/// the traffic lights, the toolbar items and the title. A Settings scene opens
/// with the preferences style (a title strip over a separate toolbar row) and
/// does not take the scene-level toolbar style.
struct UnifiedTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.toolbarStyle = .unified
            window.titleVisibility = .visible
        }
    }
}

// MARK: - Full screen

/// Enters or leaves full screen, and draws which: arrows pointing out to go
/// full screen, pointing in to come back.
struct MacFullScreenButton: View {
    @State private var isFullScreen = false

    var body: some View {
        Button(
            isFullScreen ? "Exit Full Screen" : "Enter Full Screen",
            systemImage: isFullScreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right"
        ) {
            Self.playerWindow?.toggleFullScreen(nil)
        }
        .keyboardShortcut("f", modifiers: [.command, .control])
        .labelStyle(.iconOnly)
        .help(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
        .accessibilityLabel(isFullScreen ? "Exit Full Screen" : "Enter Full Screen")
        .onAppear {
            isFullScreen = Self.playerWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }
}

extension MacFullScreenButton {
    /// The window the player is in: the key one, or the main one when another
    /// app is in front.
    static var playerWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain }
    }
}

// MARK: - Downloads

/// The titlebar's Downloads button. The list opens as a popover anchored to
/// the button, so a click anywhere else in the window puts it away, rather
/// than a sheet that holds the window until it is dismissed.
struct MacDownloadsButton: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        Button {
            appModel.downloadManagerPresented.toggle()
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .popover(isPresented: $appModel.downloadManagerPresented, arrowEdge: .bottom) {
            DownloadManagerView()
                .frame(width: 420, height: 520)
        }
    }
}

// MARK: - Bare-key transport

/// Space plays and pauses, ← and → step the queue — for the whole window, from
/// wherever the listener is.
///
/// Keep these out of menu key equivalents, which take precedence over text
/// editing. Also check the native field editor: toolbar text input can still
/// reach this handler while SwiftUI's content focus is catching up.
struct MacTransportKeys: ViewModifier {
    let controller: PlaybackController

    func body(content: Content) -> some View {
        content
            .onKeyPress(.space, phases: .down) { press in
                guard press.modifiers.isEmpty, !MacKeyboardInput.isEditingText else { return .ignored }
                controller.togglePlayPause()
                return .handled
            }
            .onKeyPress(.leftArrow, phases: .down) { press in
                guard press.modifiers.isEmpty, !MacKeyboardInput.isEditingText else { return .ignored }
                controller.previous()
                return .handled
            }
            .onKeyPress(.rightArrow, phases: .down) { press in
                guard press.modifiers.isEmpty, !MacKeyboardInput.isEditingText else { return .ignored }
                controller.next()
                return .handled
            }
    }
}

// MARK: - Inspector

/// What the inspector shows: the same panes the player uses, so a permanent
/// queue panel and the player's queue column can never disagree.
struct MacInspectorPane: View {
    let kind: MacInspectorKind
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        Group {
            switch kind {
            case .lyrics:
                MacLyricsInspector()
            case .queue:
                UpNextPane(showsCurrentTrackHeader: true)
            }
        }
        .background {
            // The panes are drawn for the player's dark backdrop and its white
            // text. The inspector gives them that backdrop rather than a second
            // light-mode styling of the same content.
            MeshBackdrop(
                seed: controller.current?.id.hashValue ?? 0,
                artwork: controller.current?.artworkData
            )
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Lyrics in the inspector, on the same clock the player uses.
///
/// The pane is handed the controller's clock and never owns one of its own,
/// exactly as the player's lyrics are.
private struct MacLyricsInspector: View {
    @Environment(PlaybackController.self) private var controller
    @State private var offsetMs = LyricsOffsetBridge.offsetMs()
    @State private var showProviderPicker = false

    var body: some View {
        LyricsPane(
                lines: controller.displayedLyrics,
                originalLines: controller.lyrics,
                loading: controller.lyricsLoading,
                clock: LyricsClock(playing: controller.isPlaying) { [controller] in
                    controller.livePosition(at: $0)
                },
                fontSize: 24,
                hasTrack: controller.current != nil,
                sourceLabel: controller.lyricsSourceLabel,
                alignmentInProgress: controller.lyricsAligning,
                alignedLocally: controller.lyricsAlignedLocally,
                alignmentState: controller.lyricsAlignmentState,
                onRetryAlignment: { controller.retryLyricsAlignment() },
                onChooseSource: { showProviderPicker = true },
                onSeek: { controller.seek(to: $0) },
                translator: controller.lyricsTranslator,
                trackId: controller.current?.id ?? "",
                offsetMs: offsetMs,
                trackTitle: controller.current?.title ?? "",
                trackArtist: controller.current?.artist ?? "",
                artworkData: controller.current?.artworkData,
                artworkUrl: controller.current?.thumbnailUrl
            )
        .onReceive(NotificationCenter.default.publisher(for: .lyricsOffsetChanged)) { _ in
            offsetMs = LyricsOffsetBridge.offsetMs()
        }
        .sheet(isPresented: $showProviderPicker) {
            LyricsProviderSheet()
        }
    }
}

#endif
