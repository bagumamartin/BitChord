#if os(iOS)
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The iPad tab's page history, for its back and forward buttons. Nil on
    /// the phone, whose pages go back with the bar's own button.
    @Entry var pageHistory: PathNavigator?
}

/// One page history per iPad tab, made when the tab is first built.
@MainActor
@Observable
final class PageHistories {
    @ObservationIgnored private var navigators: [AnyHashable: PathNavigator] = [:]

    func navigator(_ key: AnyHashable) -> PathNavigator {
        if let navigator = navigators[key] { return navigator }
        let navigator = PathNavigator()
        navigators[key] = navigator
        return navigator
    }
}

/// An iPad tab's navigation stack, bound to its page history so the top bar's
/// back and forward walk it, as the Mac window's do. A pushed page carries the
/// same leading items as the root in place of the bar's own back button.
struct PageHistoryStack<Content: View>: View {
    @Bindable var navigator: PathNavigator
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack(path: $navigator.path) {
            content
                .navigationDestination(for: PushRoute.self) { route in
                    route.make()
                        // A route replaced in place (another sidebar playlist)
                        // is a new page, not the old one's state with new values.
                        .id(route.id)
                        .navigationBarBackButtonHidden(true)
                        .toolbar { TopBarLeadingItems() }
                }
        }
        .environment(\.inBrowseStack, true)
        .environment(\.pageHistory, navigator)
    }
}

extension View {
    /// Hosts this tab root in `navigator`'s history stack.
    func historyStack(_ navigator: PathNavigator) -> some View {
        PageHistoryStack(navigator: navigator) { self }
    }
}

/// The edge swipe back, kept where a page has hidden the bar's back button for
/// the top bar's own (`PageHistoryStack`): UIKit turns the swipe off with it.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// The foot of the iPad's sidebar: the account and Settings, as the Mac's
/// sidebar has them.
struct IPadSidebarFooter: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AuthController.self) private var auth

    var body: some View {
        HStack(spacing: 10) {
            TopBarAccountButton()
            Text(auth.signedIn ? (auth.accountName ?? "Account") : "Not signed in")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(auth.signedIn ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                appModel.settingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .scaledFont(size: 17, weight: .medium)
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(ProfileCircleButtonStyle())
            .accessibilityLabel("Settings")
        }
    }
}

/// A playlist's artwork for its sidebar row: small, rounded, drawn ahead, since
/// the row's icon is an image rather than a view.
enum SidebarArtwork {
    static let side: CGFloat = 26
    static let likedMusicId = "LM"

    /// Liked Music's tile in YouTube's colours: a thumbs-up on its purple to
    /// pink gradient.
    @MainActor
    static let likedMusic: UIImage = {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size).image { context in
            UIBezierPath(roundedRect: rect, cornerRadius: 5).addClip()
            let colors = [
                UIColor(red: 0.62, green: 0.42, blue: 0.96, alpha: 1).cgColor,
                UIColor(red: 0.96, green: 0.38, blue: 0.70, alpha: 1).cgColor,
            ]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: side, y: side),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.5, weight: .semibold)
            if let thumb = UIImage(systemName: "hand.thumbsup.fill", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                let size = thumb.size
                thumb.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
            }
        }
    }()

    static func load(_ url: String) async -> UIImage? {
        let scale = await UIScreen.main.scale
        guard let sized = SharedArtwork.sized(url, Int(side * scale)),
              let address = URL(string: sized),
              let (data, _) = try? await URLSession.shared.data(from: address),
              let image = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            UIBezierPath(roundedRect: rect, cornerRadius: 5).addClip()
            image.draw(in: rect)
        }
    }
}
/// Keeps the sidebar's playlist rows from ever becoming the selected tab.
///
/// The adaptable tab bar adds the section of any tab selected from the sidebar
/// to the bar, and keeps it there afterwards. A playlist row is a way into
/// Library > Playlists rather than a tab, so its selection is refused before
/// UIKit commits it and handed to `onPlaylist` instead, by its place in the
/// section (UIKit's identifiers for SwiftUI's tabs are its own). SwiftUI owns
/// the tab bar controller's delegate; this stands in front of it and forwards
/// the rest.
final class SidebarSelectionGuard: NSObject, UITabBarControllerDelegate {
    static let shared = SidebarSelectionGuard()
    static let sectionTitle = String(localized: "Playlists")

    weak var original: UITabBarControllerDelegate?
    var onPlaylist: (Int) -> Void = { _ in }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        if let section = tab.parent, section.title == Self.sectionTitle,
           let index = section.children.firstIndex(where: { $0 === tab }) {
            onPlaylist(index)
            return false
        }
        return original?.tabBarController?(tabBarController, shouldSelectTab: tab) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

/// Installs the `SidebarSelectionGuard` on the tab bar controller above it.
struct SidebarSelectionGuardInstaller: UIViewRepresentable {
    func makeUIView(context: Context) -> ProbeView { ProbeView() }
    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            install(tries: 10)
        }

        func install(tries: Int) {
            let guardian = SidebarSelectionGuard.shared
            guard window != nil, tries > 0 else { return }
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let controller = next as? UITabBarController {
                    if controller.delegate !== guardian {
                        guardian.original = controller.delegate
                        controller.delegate = guardian
                    }
                    return
                }
                responder = next
            }
            // Not yet in the controller's view: try again once it is.
            DispatchQueue.main.async { [weak self] in
                self?.install(tries: tries - 1)
            }
        }
    }
}

#endif
