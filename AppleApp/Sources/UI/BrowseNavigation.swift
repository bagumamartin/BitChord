import SwiftUI
import BitChordShared

/// A page pushed from a browse view, as a value the Mac's window history can
/// hold and push again.
///
/// The pages are built by closures rather than named in an enum because they
/// are many and varied (an album, a mood's playlists, a library grid). Two
/// routes are the same route only if they are the same push: going forward
/// re-pushes the very page that was popped.
struct PushRoute: Hashable {
    let id: UUID
    let make: () -> AnyView

    static func == (lhs: PushRoute, rhs: PushRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension EnvironmentValues {
    /// True inside the Mac's one browse stack, where a page's own stack would
    /// nest inside it and its pushes would bypass the window's history.
    @Entry var inBrowseStack = false
}

/// Search remains one tap away from every browsing tab, including when the
/// tab bar is hidden by the iPad search field.
struct TopBarSearchButton: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button {
            appModel.nowPlayingPresented = false
            appModel.requestedTab = .search
            appModel.focusSearch = true
            appModel.searchFocusTrigger &+= 1
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Search")
        .accessibilityLabel("Search")
    }
}

/// A browse page's navigation stack: its own on iOS, the window's on the Mac.
struct PageStack<Content: View>: View {
    @Environment(\.inBrowseStack) private var inBrowseStack
    @ViewBuilder var content: Content

    var body: some View {
        if inBrowseStack {
            content
        } else {
            NavigationStack {
                content
                    .navigationDestination(for: PushRoute.self) { $0.make() }
            }
        }
    }
}

/// A link to a browse page. Inside the Mac's browse stack it pushes a value,
/// so the push is part of the window's back/forward history; elsewhere it is
/// an ordinary destination link.
struct PushLink<Label: View, Destination: View>: View {
    @Environment(\.inBrowseStack) private var inBrowseStack
    /// One identity per link, kept across redraws. A fresh value on every
    /// body pass never matches the path the stack holds, and the stack redraws
    /// the links under a pushed page to compare them: an endless layout loop.
    @State private var id = UUID()
    private let destination: () -> Destination
    private let label: Label

    init(destination: Destination, @ViewBuilder label: () -> Label) {
        self.destination = { destination }
        self.label = label()
    }

    init(@ViewBuilder destination: @escaping () -> Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    var body: some View {
        if inBrowseStack {
            let make = destination
            NavigationLink(value: PushRoute(id: id, make: { AnyView(make()) })) { label }
        } else {
            NavigationLink(destination: destination) { label }
        }
    }
}

extension PushLink where Label == Text {
    init(_ title: LocalizedStringKey, @ViewBuilder destination: @escaping () -> Destination) {
        self.init(destination: destination) { Text(title) }
    }
}

/// A window history the titlebar's back and forward buttons can walk.
@MainActor
protocol HistoryNavigating: AnyObject, Observable {
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    func goBack()
    func goForward()
}

/// A history of one stack's pages: a window with no sidebar (Settings), or
/// one of the iPad's tabs.
@MainActor
@Observable
final class PathNavigator: HistoryNavigating {
    private(set) var history: [[PushRoute]] = [[]]
    private(set) var index = 0

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < history.count - 1 }

    var path: [PushRoute] {
        get { history[index] }
        set {
            guard newValue != history[index] else { return }
            history.removeSubrange((index + 1)...)
            history.append(newValue)
            index = history.count - 1
        }
    }

    func goBack() { if canGoBack { index -= 1 } }
    func goForward() { if canGoForward { index += 1 } }
}

#if os(macOS)
/// The Mac window's history: which sidebar row, and which pages pushed on it.
///
/// Back and forward walk whole locations, as Music and Finder do: from an album
/// opened on Listen Now, back returns to Listen Now; from there, back returns to
/// whichever row was showing before it, and forward retraces both steps.
@MainActor
@Observable
final class MacNavigator: HistoryNavigating {
    struct Location: Equatable {
        var side: MacSide
        var path: [PushRoute]
        /// The full player was showing over this location when a page was
        /// opened from it, so arriving back here reopens the player.
        var showedPlayer = false
    }

    /// Called when back arrives at a location the player was showing over.
    var onReturnToPlayer: (() -> Void)?

    /// Pushes a page opened from the player, with the player as the step back.
    func pushFromPlayer(_ route: PushRoute) {
        history[index].showedPlayer = true
        visit(Location(side: current.side, path: current.path + [route]))
    }

    private(set) var history: [Location]
    private(set) var index = 0
    private static let limit = 100

    init(side: MacSide = .home) {
        history = [Location(side: side, path: [])]
    }

    var current: Location { history[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < history.count - 1 }

    var side: MacSide {
        get { current.side }
        set {
            // Choosing the row already showing returns to its root page.
            visit(Location(side: newValue, path: []))
        }
    }

    var path: [PushRoute] {
        get { current.path }
        set { visit(Location(side: current.side, path: newValue)) }
    }

    /// Shows `side` without making the old location a step back: a restored
    /// window, or a row that no longer exists.
    func replaceSide(_ side: MacSide) {
        history[index] = Location(side: side, path: [])
    }

    func goBack() {
        guard canGoBack else { return }
        index -= 1
        if history[index].showedPlayer {
            // Once: after the player is closed again, this location is an
            // ordinary page, and walking back through it later should not
            // pop the player up.
            history[index].showedPlayer = false
            onReturnToPlayer?()
        }
    }

    func goForward() {
        guard canGoForward else { return }
        index += 1
    }

    private func visit(_ location: Location) {
        guard location != current else { return }
        history.removeSubrange((index + 1)...)
        history.append(location)
        if history.count > Self.limit {
            history.removeFirst(history.count - Self.limit)
        }
        index = history.count - 1
    }
}

/// The titlebar's back and forward buttons.
struct MacHistoryButtons<Navigator: HistoryNavigating>: View {
    let navigator: Navigator

    var body: some View {
        ControlGroup {
            Button {
                navigator.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!navigator.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")
            .keyboardShortcut("[", modifiers: .command)

            Button {
                navigator.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!navigator.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")
            .keyboardShortcut("]", modifiers: .command)
        }
        .controlGroupStyle(.navigation)
    }
}
#endif
