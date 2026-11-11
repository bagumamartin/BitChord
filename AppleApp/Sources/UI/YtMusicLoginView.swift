import SwiftUI
import WebKit
import BitChordShared

/// Google's login stays in an isolated WebKit cookie store. Reaching Music
/// presents a native completion step; the listener still explicitly confirms
/// the live page's profile, as upstream does. Account/channel selection can
/// reopen the same page without replacing its web view or losing its cookies.
struct YtMusicLoginView: View {
    @Environment(AuthController.self) private var auth
    var onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
    var onDismiss: () -> Void

    @State private var flow = LoginFlow()
    @State private var adoptingSharedSession = false

    var body: some View {
        VStack(spacing: 0) {
            if let offer = auth.sharedSessionOffer {
                sharedSessionAdoptionPrompt(offer)
            } else if !flow.showsCompletion, let prompt = flow.prompt {
                VStack(spacing: 10) {
                    Text(prompt)
                        .font(.footnote)
                        .foregroundStyle(flow.captureFailedMessage == nil ? Color.secondary : Color.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            if auth.sharedSessionOffer == nil {
                ZStack {
                    // Keep the browser alive under the completion screen. Returning
                    // to Google's avatar menu must use this exact session.
                    LoginWebView(
                        flow: flow,
                        onCaptured: onCaptured,
                        onUnavailable: { reason in flow.captureFailed(reason) }
                    )
                    .opacity(flow.showsCompletion ? 0 : 1)
                    .allowsHitTesting(!flow.showsCompletion)
                    .accessibilityHidden(flow.showsCompletion)

                    if flow.showsCompletion {
                        SignInCompletionStep(
                            flow: flow,
                            onConfirm: { flow.session.take?() },
                            onChoose: { flow.chooseProfile() }
                        )
                    }
                }
            }
        }
        .navigationTitle(auth.sharedSessionOffer != nil
            ? "Use shared session?"
            : (flow.showsCompletion ? "Finish signing in" : "Sign in to YouTube Music"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .interactiveDismissDisabled(flow.taking || adoptingSharedSession)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: onDismiss)
                    .disabled(flow.taking || adoptingSharedSession)
                    #if os(macOS)
                    .keyboardShortcut(.cancelAction)
                    #endif
            }
            ToolbarItem(placement: .confirmationAction) {
                if auth.sharedSessionOffer == nil && flow.pageReady && !flow.showsCompletion {
                    Button("Use This Profile") { flow.session.take?() }
                }
            }
        }
    }

    @ViewBuilder
    private func sharedSessionAdoptionPrompt(_ offer: SharedSessionCredential) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "key.icloud")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
            Text("Use \(offer.accountName.isEmpty ? offer.email : offer.accountName)’s BitChord session from \(offer.deviceName)?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = auth.sessionUnavailableReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
            Button {
                adoptingSharedSession = true
                auth.adoptSharedSessionOffer { accepted in
                    adoptingSharedSession = false
                    if accepted { onDismiss() }
                }
            } label: {
                if adoptingSharedSession {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Text("Use This Session").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(adoptingSharedSession)

            Button("Sign in another way") {
                auth.dismissSharedSessionOffer()
            }
            .disabled(adoptingSharedSession)
        }
        .padding(28)
        .frame(maxWidth: 460, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

}

/// A native review card. Kept separate so loading, unavailable, and verified
/// profile layouts can be previewed without starting a browser or an account.
struct SignInCompletionStep: View {
    let flow: LoginFlow
    var onConfirm: () -> Void
    var onChoose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var contentWidth: CGFloat {
        #if os(macOS)
        400
        #else
        440
        #endif
    }

    private var avatarSize: CGFloat {
        #if os(macOS)
        72
        #else
        88
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Text(flow.taking ? "Signing you in" : "Confirm your profile")
                            .font(.title2.weight(.semibold))
                        Text("Connect your YouTube Music profile to BitChord.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if let profile = flow.profile {
                        profileCard(profile)
                    } else if flow.taking {
                        Image(systemName: "person.crop.circle")
                            .scaledFont(size: 64, weight: .light)
                            .foregroundStyle(.secondary)
                    } else if flow.checkingPage || flow.loadingProfile {
                        VStack(spacing: 16) {
                            ProgressView()
                            Text("Loading your profile…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .scaledFont(size: 48, weight: .light)
                                .foregroundStyle(.secondary)
                            Text("Review your profile on Google")
                                .font(.headline)
                            Text("Your profile details couldn’t be loaded. You can still review and confirm them on the Google page.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = flow.captureFailedMessage {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if flow.taking {
                        ProgressView("Verifying your profile…")
                        Text("Finishing sign-in to BitChord.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if flow.profile != nil || flow.checkingPage || flow.loadingProfile {
                        profileActions(availableWidth: geometry.size.width)
                        Text("Your library and recommendations will use this profile.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: onChoose) {
                            Text("Review Profile on Google")
                        }
                        .buttonStyle(.borderedProminent)
                        #if os(macOS)
                        .controlSize(.regular)
                        .keyboardShortcut(.defaultAction)
                        #else
                        .controlSize(.large)
                        #endif
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: contentWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
    }

    @ViewBuilder
    private func profileActions(availableWidth: CGFloat) -> some View {
        #if os(macOS)
        HStack(spacing: 12) {
            chooseButton(fullWidth: false)
            confirmButton(fullWidth: false)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        #else
        if availableWidth >= 520 && !dynamicTypeSize.isAccessibilitySize {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    chooseButton(fullWidth: false)
                    confirmButton(fullWidth: false)
                }
                .fixedSize(horizontal: true, vertical: false)
                stackedActions
            }
            .frame(maxWidth: .infinity)
        } else {
            stackedActions
        }
        #endif
    }

    private var stackedActions: some View {
        VStack(spacing: 12) {
            confirmButton(fullWidth: true)
            chooseButton(fullWidth: true)
        }
    }

    private func confirmButton(fullWidth: Bool) -> some View {
        Button(action: onConfirm) {
            Text("Use This Profile")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        #if os(macOS)
        .controlSize(.regular)
        .keyboardShortcut(.defaultAction)
        #else
        .controlSize(.large)
        #endif
        .disabled(!flow.pageReady || flow.loadingProfile)
    }

    private func chooseButton(fullWidth: Bool) -> some View {
        Button(action: onChoose) {
            Text("Choose another profile")
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        #if os(macOS)
        .controlSize(.regular)
        #else
        .controlSize(.large)
        #endif
        .disabled(flow.loadingProfile || flow.checkingPage)
    }

    private func profileCard(_ profile: SignInProfilePreview) -> some View {
        VStack(spacing: 16) {
            AsyncImage(url: profile.avatarURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(Color.accentColor.opacity(0.12))
                        .overlay {
                            Text(profile.initials)
                                .font(.title.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                }
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())
            .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(profile.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle = profile.subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Color.primary.opacity(0.06)) }
        .accessibilityElement(children: .combine)
    }
}

/// Read-only account_menu request for this candidate, without applying its
/// cookie/scope to Innertube or touching Keychain. Uses the existing shared
/// signing functions and the same account endpoint/parser shape as upstream.
@MainActor
enum SignInProfileLoader {
    static func request(cookie: String, fields: SignInCaptureFields) -> URLRequest? {
        guard fields.loggedIn,
              let secret = Innertube.shared.sapisidFrom(cookieHeader: cookie),
              let version = fields.clientVersion else { return nil }
        let origin = "https://music.youtube.com"
        var request = URLRequest(url: URL(string: origin + "/youtubei/v1/account/account_menu?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        var client: [String: Any] = ["clientName": "WEB_REMIX", "clientVersion": version, "hl": "en", "gl": "US"]
        if let visitor = fields.visitorData { client["visitorData"] = visitor }
        var user: [String: Any] = ["lockedSafetyMode": false]
        if let identity = SignInProfileScope(fields).dataSyncId { user["onBehalfOfUser"] = identity }
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["context": ["client": client, "user": user, "request": ["useSsl": true]]])
        for (name, value) in [
            "Content-Type": "application/json", "Origin": origin, "X-Origin": origin,
            "Referer": origin + "/", "User-Agent": SignInUserAgent.desktopSafari(),
            "X-YouTube-Client-Name": "67", "X-YouTube-Client-Version": version,
            "Cookie": cookie, "Authorization": Innertube.shared.sapisidHash(sapisid: secret, origin: origin)
        ] { request.setValue(value, forHTTPHeaderField: name) }
        if let account = fields.authUser { request.setValue(account, forHTTPHeaderField: "X-Goog-AuthUser") }
        if let page = fields.pageId { request.setValue(page, forHTTPHeaderField: "X-Goog-PageId") }
        if let visitor = fields.visitorData { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        return request
    }

    static func load(cookie: String, fields: SignInCaptureFields) async -> SignInProfilePreview? {
        guard let request = request(cookie: cookie, fields: fields),
              let data = try? await GuardedHTTP.shared.data(for: request) else { return nil }
        return SignInProfilePreview.parse(data)
    }
}

#if os(macOS)
private struct LoginWebView: NSViewRepresentable {
    let flow: LoginFlow
    var onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(
            flow: flow,
            onCaptured: onCaptured,
            onUnavailable: onUnavailable
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static func dismantleNSView(_ nsView: WKWebView, coordinator: LoginWebCoordinator) {
        coordinator.stopObserving()
    }
}
#else
private struct LoginWebView: UIViewRepresentable {
    let flow: LoginFlow
    var onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
    var onUnavailable: (String) -> Void

    func makeCoordinator() -> LoginWebCoordinator {
        LoginWebCoordinator(
            flow: flow,
            onCaptured: onCaptured,
            onUnavailable: onUnavailable
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView()
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: LoginWebCoordinator) {
        coordinator.stopObserving()
    }
}
#endif

/// Conformed to `WKHTTPCookieStoreObserver` only so it can be registered and
/// unregistered; the observer callback is not used. Nothing is captured from it —
/// the listener confirms — and it only matters that the store is registered, so
/// that the jar is written to the store the harvest reads.
///
/// `@MainActor` because every navigation delegate callback WebKit makes is made on
/// the main thread, and because [flow] is observed SwiftUI state: the cookie-store
/// completion handlers are the only thing here that is not, and those hop to the
/// main actor themselves rather than mutating observed state off it.
@MainActor
final class LoginWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let flow: LoginFlow
    private let onCaptured: (SignInCapture, @escaping (Bool) -> Void) -> Void
    private let onUnavailable: (String) -> Void
    private let profileLoader: (String, SignInCaptureFields) async -> SignInProfilePreview?
    private let store: WKWebsiteDataStore
    private var captured = false
    private var active = true
    private var navigationRevision = 0
    private var pageProbeTask: Task<Void, Never>?
    /// Weak, because the coordinator is the navigation delegate the web view
    /// retains, and a strong reference back would be a cycle.
    private weak var webView: WKWebView?

    init(
        flow: LoginFlow,
        onCaptured: @escaping (SignInCapture, @escaping (Bool) -> Void) -> Void,
        onUnavailable: @escaping (String) -> Void,
        profileLoader: @escaping (String, SignInCaptureFields) async -> SignInProfilePreview? = SignInProfileLoader.load
    ) {
        self.store = WKWebsiteDataStore.nonPersistent()
        self.flow = flow
        self.onCaptured = onCaptured
        self.onUnavailable = onUnavailable
        self.profileLoader = profileLoader
    }

    func stopObserving() {
        active = false
        navigationRevision += 1
        pageProbeTask?.cancel()
        pageProbeTask = nil
        flow.session.take = nil
        store.httpCookieStore.remove(self)
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView = nil
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        // Deliberately empty. Registering is the point; observing is not. Nothing
        // is captured from here — a cookie changing is not a settled identity.
    }

    func makeWebView(loadInitialPage: Bool = true) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Google's own refusal of embedded web views: on iOS WebKit sends a
        // *mobile* agent, and `accounts.google.com` answers that with "This
        // browser or app may not be secure" before the password is ever typed.
        // Upstream hits none of this because Android's `WebView` is a system
        // browser Google allowlists, and it sets no agent of its own.
        //
        // `applicationNameForUserAgent` would only *append* to the engine's agent,
        // leaving the mobile one in front, so the whole string is replaced. See
        // `SignInUserAgent` for why this is the shape it is and why
        // `ASWebAuthenticationSession` is not the answer.
        config.applicationNameForUserAgent = nil
        // The navigation delegate also refuses app schemes in popup requests.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let webView = WKWebView(frame: .zero, configuration: config)
        if SignInUserAgent.needsReplacing(defaultAgent: webView.customUserAgent ?? "") {
            webView.customUserAgent = SignInUserAgent.desktopSafari()
        }
        store.httpCookieStore.add(self)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        // How the confirmation button reaches the session. Set here rather than
        // handed back to the view as state — see [LoginFlow.session].
        flow.session.take = { [weak self] in self?.takeSession() }
        if loadInitialPage { webView.load(URLRequest(url: Self.loginURL)) }
        return webView
    }

    // ---- what the login page is allowed to do ------------------------------

    /// What to do with a navigation, given where it points.
    ///
    /// A thin re-export of [SignInNavigation.decision] rather than a rule of its
    /// own, so the one place the rule is written is also the one place it is
    /// checked. A second copy here would be a second answer to the same question,
    /// and the one that shipped is the one nobody would remember to update.
    static func navigationDecision(for url: URL?) -> SignInNavigation.Decision {
        SignInNavigation.decision(for: url)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        // A nil target frame is a new window, which is `createWebViewWith`'s to
        // answer; only a real main frame is "where the sign-in is now".
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        switch Self.navigationDecision(for: url) {
        case .load:
            decisionHandler(.allow)
            noteMainFrame(url, isMainFrame: isMainFrame)
        case .refuse(let why):
            // Cancelled, and *only* cancelled. There is no branch here that hands
            // a URL to the system: following one is what opened the YouTube Music
            // app and lost the sign-in, and the only way to be sure that cannot
            // happen again is for the capability not to exist on this screen.
            decisionHandler(.cancel)
            NSLog("[BitChord] sign-in refused scheme: \(url?.scheme ?? "unknown")")
            flow.refusal = why
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // A `target="_blank"` link, decided exactly as any other navigation.
        // Loading it unconditionally is how a `youtube://` link in a new window
        // got followed.
        let url = navigationAction.request.url
        switch Self.navigationDecision(for: url) {
        case .load:
            if let url { webView.load(URLRequest(url: url)) }
            noteMainFrame(url, isMainFrame: true)
        case .refuse(let why):
            NSLog("[BitChord] sign-in refused popup scheme: \(url?.scheme ?? "unknown")")
            flow.refusal = why
        }
        return nil
    }

    private func noteMainFrame(_ url: URL?, isMainFrame: Bool) {
        guard active, isMainFrame else { return }
        navigationRevision += 1
        pageProbeTask?.cancel()
        flow.navigating(to: url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        noteMainFrame(webView.url, isMainFrame: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        noteMainFrame(webView.url, isMainFrame: true)
        guard active else { return }
        guard SignInNavigation.isMusicOrigin(webView.url) else { return }
        let revision = navigationRevision
        // Inspection controls presentation only. It does not harvest cookies or
        // call onCaptured. A late ytcfg or an unfinished channel chooser stays in
        // the browser; a signed-in page gets the explicit completion screen.
        pageProbeTask = Task { @MainActor [weak self, weak webView] in
            for attempt in 0..<3 {
                guard let self, let webView, self.active, !Task.isCancelled,
                      self.navigationRevision == revision,
                      SignInNavigation.isMusicOrigin(webView.url) else { return }
                let raw = try? await webView.evaluateJavaScript(Self.ytcfgProbe, in: nil, contentWorld: .page)
                guard self.active, !Task.isCancelled, self.navigationRevision == revision else { return }
                if let fields = SignInCapture.parse(jsResult: raw), fields.loggedIn {
                    self.flow.inspectedPage(loggedIn: true)
                    self.flow.loadingProfile = true
                    await self.loadProfile(from: webView, fields: fields, revision: revision)
                    return
                }
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(200)) }
            }
            guard let self, self.active, !Task.isCancelled, self.navigationRevision == revision else { return }
            self.flow.inspectedPage(loggedIn: false)
        }
    }

    private func loadProfile(from view: WKWebView, fields: SignInCaptureFields, revision: Int) async {
        let cookies = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        guard active, !Task.isCancelled, navigationRevision == revision else { return }
        let profile = await profileLoader(Self.cookieHeader(cookies), fields)
        guard active, !Task.isCancelled, navigationRevision == revision else { return }
        let raw = try? await view.evaluateJavaScript(Self.ytcfgProbe, in: nil, contentWorld: .page)
        guard active, !Task.isCancelled, navigationRevision == revision else { return }
        flow.loadingProfile = false
        guard let current = SignInCapture.parse(jsResult: raw), current.loggedIn,
              SignInProfileScope(current) == SignInProfileScope(fields) else {
            flow.chooseProfile()
            flow.captureFailed("The selected profile changed. Review it on Google before confirming.")
            return
        }
        flow.profile = profile
        flow.profileScope = profile == nil ? nil : SignInProfileScope(fields)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        let error = error as NSError
        guard active, error.code != NSURLErrorCancelled else { return }
        // Our refusal of an app link may finish as WebKit's policy-change
        // error. Keep the existing page/profile available after that refusal.
        if flow.refusal != nil, error.domain == "WebKitErrorDomain", error.code == 102 { return }
        navigationRevision += 1
        pageProbeTask?.cancel()
        flow.inspectedPage(loggedIn: false)
        flow.captureFailed("The sign-in page could not load. Check your connection and try again.")
    }

    // ---- taking the session -------------------------------------------------

    /// The `ytcfg` check is upstream's and it is not decoration. A login in
    /// progress has *already* been given a SAPISID by the time the password is
    /// typed, so a jar that merely has a signing secret in it is evidence of
    /// nothing — and storing one of those is how a sign-in appears to succeed and
    /// then reports signed out on the next launch. `LOGGED_IN` on the page is the
    /// claim that the identity has settled.
    private func takeSession() {
        guard active, !captured, !flow.taking else { return }
        guard flow.pageReady, let view = webView,
              SignInNavigation.isMusicOrigin(view.url), !view.isLoading else {
            flow.captureFailed("Finish signing in and selecting your profile on the Google page first.")
            return
        }
        flow.taking = true
        flow.refusal = nil
        flow.captureFailedMessage = nil
        let revision = navigationRevision
        store.httpCookieStore.getAllCookies { [weak self, weak view] cookies in
            let header = Self.cookieHeader(cookies)
            Task { @MainActor in
                guard let self, let view, self.active else { return }
                guard self.navigationRevision == revision,
                      SignInNavigation.isMusicOrigin(view.url), !view.isLoading else {
                    self.finish(message: "The profile changed. Finish selecting it, then try again.")
                    return
                }
                guard AuthBridge.shared.hasApiSid(cookieHeader: header) else {
                    self.finish(message: "Google has not issued a session yet. Try again in a moment.")
                    return
                }
                let raw = try? await view.evaluateJavaScript(Self.ytcfgProbe, in: nil, contentWorld: .page)
                guard self.active else { return }
                guard self.navigationRevision == revision,
                      SignInNavigation.isMusicOrigin(view.url), !view.isLoading,
                      let fields = SignInCapture.parse(jsResult: raw), fields.loggedIn else {
                    self.finish(message: "No signed-in profile is available on this page yet. Finish selecting your profile, then try again.")
                    return
                }
                if let displayed = self.flow.profileScope, displayed != SignInProfileScope(fields) {
                    self.flow.chooseProfile()
                    self.finish(message: "The selected profile changed. Review it on Google before confirming.")
                    return
                }
                let dataSyncId = fields.pageId ?? SignInCapture.normalizeDataSyncId(fields.dataSyncId)
                self.captured = true
                // Keep Checking visible until the existing verification and
                // durable save finish. Capture alone is not a successful login.
                self.onCaptured(
                    SignInCapture(
                        cookie: header,
                        pageId: fields.pageId,
                        dataSyncId: dataSyncId,
                        authUser: fields.authUser,
                        visitorData: fields.visitorData,
                        clientVersion: fields.clientVersion,
                        loggedIn: true
                    )
                ) { [weak self] accepted in
                    Task { @MainActor in
                        guard let self, self.active else { return }
                        if accepted {
                            self.flow.captureSucceeded()
                        } else {
                            self.captured = false
                            self.finish(message: "Your profile could not be verified or saved. Try again, or choose a different profile.")
                        }
                    }
                }
            }
        }
    }

    private func finish(message: String) {
        onUnavailable(message)
    }

    /// Upstream's `YTCFG_PROBE`, unchanged in substance: `ytcfg` is the page's
    /// own account configuration, and `LOGGED_IN` is the only claim on it that
    /// means an identity has settled. It returns an object rather than a string
    /// so the web view serialises it — a probe that stringified its own result
    /// would come back double-encoded on Android.
    private static let ytcfgProbe = """
    (function () {
      try {
        if (!window.ytcfg || !window.ytcfg.get) return null;
        var get = function (key) {
          var value = window.ytcfg.get(key);
          return (value === undefined || value === null || value === '') ? null : String(value);
        };
        return {
          loggedIn: String(!!window.ytcfg.get('LOGGED_IN')),
          pageId: get('DELEGATED_SESSION_ID'),
          dataSyncId: get('DATASYNC_ID'),
          authUser: get('SESSION_INDEX'),
          visitorData: get('VISITOR_DATA'),
          clientVersion: get('INNERTUBE_CLIENT_VERSION')
        };
      } catch (e) {
        return null;
      }
    })()
    """

    /// Upstream `CookieManager.getCookie(MUSIC_ORIGIN)`: only cookies the browser
    /// would send to music.youtube.com. Mixing a `.google.com` SID with YouTube's
    /// SAPISID is a different account than the Music one.
    private static func cookieHeader(_ cookies: [HTTPCookie]) -> String {
        guard let url = URL(string: musicOrigin + "/") else { return "" }
        return cookies
            .filter { wouldSend($0, to: url) }
            .filter { !$0.value.isEmpty }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func wouldSend(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if cookie.isSecure, url.scheme != "https" { return false }
        if let expiry = cookie.expiresDate, expiry < Date() { return false }
        let domain = cookie.domain.lowercased()
        let hostOnly = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        let hostMatch = host == hostOnly || host.hasSuffix("." + hostOnly)
        guard hostMatch else { return false }
        let path = url.path.isEmpty ? "/" : url.path
        let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
        return path.hasPrefix(cookiePath)
    }

    private static let musicOrigin = "https://music.youtube.com"
    private static let loginURL = URL(string:
        "https://accounts.google.com/ServiceLogin" +
        "?ltmpl=music&service=youtube&prompt=select_account" +
        "&continue=https%3A%2F%2Fmusic.youtube.com%2F"
    )!
}
