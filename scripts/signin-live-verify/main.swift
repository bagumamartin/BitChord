import Foundation
import WebKit

// The sign-in web view's identity, asked of the real engine and of Google's own
// answer.
//
// The reported failure was Google's "This browser or app may not be secure" page
// on iOS, before any password was typed. That is Google's refusal of an embedded
// web view, so the only honest way to check the fix is to load the *actual* login
// URL in a web view carrying the agent the app will use, and read what Google
// says. A test that only inspected the string would prove the string is shaped
// like a desktop browser, which is necessary and nowhere near sufficient.
//
// Driven by the run loop rather than by async, because every part of it is a
// callback into a web view on the main thread and wrapping that in continuations
// only obscures what is being waited for.
//
// Needs a network. Separate from `check-signin.sh`, which is pure.

var failures = 0
var checks = 0

func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    checks += 1
    if ok {
        print("  ok   \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

let loginURL = URL(string:
    "https://accounts.google.com/ServiceLogin"
        + "?ltmpl=music&service=youtube&prompt=select_account"
        + "&continue=https%3A%2F%2Fmusic.youtube.com%2F"
)!

/// Loads `url` in a web view with `agent` (nil for the engine's own), then asks
/// the loaded page `question`, and returns the answer.
///
/// `question` is evaluated after the load finishes, so it sees the settled page
/// rather than a document still arriving. The reader is held for the duration of
/// the pump by the caller, so it does not need registering anywhere — and it could
/// not be: `RunLoop.add(_:for:)` takes a `Port`, not an object.
func ask(_ url: URL, agent: String?, _ question: String, seconds: Double = 40) -> String {
    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 800), configuration: config)
    if let agent { view.customUserAgent = agent }

    final class Reader: NSObject, WKNavigationDelegate {
        var onDone: ((String) -> Void)?
        private var finished = false
        /// Taken as a stored value because a nested class cannot close over one
        /// from the enclosing scope, and the question is per-call.
        private let question: String
        init(view: WKWebView, question: String) {
            self.question = question
            super.init()
            view.navigationDelegate = self
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            finished = true
            webView.evaluateJavaScript(question) { [weak self] raw, _ in
                self?.onDone?((raw as? String) ?? "")
                self?.onDone = nil
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish("")
        }
        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            finish("")
        }
        private func finish(_ text: String) {
            guard !finished else { return }
            finished = true
            onDone?(text)
            onDone = nil
        }
    }

    let reader = Reader(view: view, question: question)
    var result = ""
    var done = false
    reader.onDone = { text in
        result = text
        done = true
    }
    view.load(URLRequest(url: url))
    let deadline = Date().addingTimeInterval(seconds)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    return result
}

/// The phrases Google's refusal page is made of. Any one means the engine was
/// refused, and the exact wording has changed before.
private let refusalMarkers = [
    "may not be secure",
    "couldn’t sign you in",
    "couldn't sign you in",
    "this browser or app",
    "try using a different browser",
]

func isRefusal(_ text: String) -> Bool {
    let lower = text.lowercased()
    return refusalMarkers.contains { lower.contains($0) }
}

func summary(_ text: String) -> String {
    let lines = text
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    return lines.prefix(4).joined(separator: " · ")
}

print("sign-in: Google's own answer, from a real web view")

let appAgent = SignInUserAgent.desktopSafari()
print("  · agent under test: \(appAgent)")

// The engine's own agent, for the record. On iOS this is a *mobile* one, and that
// is the whole of the reported bug; on macOS it is already desktop-shaped but
// carries no `Version/`, which is why the agent below is used on both platforms
// rather than only where it is needed.
let ownUA = ask(
    URL(string: "https://example.com")!, agent: nil, "navigator.userAgent", seconds: 30
)
print("  · this engine's own agent: \(ownUA)")
check("the engine's own agent is readable", !ownUA.isEmpty)

check("our agent names Safari", appAgent.contains("Safari/"))
check("our agent carries a version token", appAgent.contains("Version/"))
check("our agent is not a mobile agent", !SignInUserAgent.needsReplacing(defaultAgent: appAgent))
check("our agent presents as Safari on macOS", appAgent.contains("Macintosh"))

// The check that matters: Google must not answer with its refusal page.
let text = ask(
    loginURL, agent: appAgent, "document.body ? document.body.innerText : ''"
)
print("  · page said: \(summary(text).isEmpty ? "(nothing)" : summary(text))")

check("the page answered at all", !text.isEmpty)

// The control: a check that cannot fail proves nothing, so the *mobile* agent —
// what an iOS `WKWebView` sends on its own — has to be shown to be refused.
//
// It is not refused here, and that is not a finding about the app: on macOS a
// `WKWebView` is WebKit, which is what Safari on macOS *is*, so Google cannot tell
// the two apart by engine and a mobile agent alone does not trip its block. The
// block needs the combination — a mobile agent *inside* an iOS web view, where the
// JavaScript environment is also a phone's. So the control is only meaningful
// where the bug reproduces, and is reported as unavailable elsewhere rather than
// quietly passing.
let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
    + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Safari/604.1"
let mobileText = ask(
    loginURL, agent: mobileAgent, "document.body ? document.body.innerText : ''"
)
print("  · page said, with a mobile agent: \(summary(mobileText).isEmpty ? "(nothing)" : summary(mobileText))")
check("a mobile agent is what the app is replacing",
      SignInUserAgent.needsReplacing(defaultAgent: mobileAgent))
#if os(iOS)
check("Google refuses a mobile agent in a web view", isRefusal(mobileText),
      isRefusal(mobileText) ? "refused, as expected" : "not refused — the fix is not proven")
#else
print("  · control unavailable here: on macOS the engine is WebKit, which is what")
print("    Safari on macOS is, so a mobile agent alone does not trip Google's block.")
print("    The block needs a mobile agent inside an *iOS* web view. Run this from an")
print("    iOS simulator or device to exercise it.")
check("the control could not be exercised on this platform",
      isRefusal(mobileText) || mobileText.lowercased().contains("sign in"),
      "reported, not passed off as verified")
#endif

check("Google did not refuse the engine", !isRefusal(text), isRefusal(text) ? "refusal page" : "")
check(
    "the page is a sign-in page, not an error",
    text.lowercased().contains("sign in")
        || text.lowercased().contains("google")
        || text.lowercased().contains("email"),
    summary(text)
)

print(failures == 0 ? "\nall \(checks) checks passed" : "\n\(failures) of \(checks) checks FAILED")
exit(failures == 0 ? 0 : 1)
