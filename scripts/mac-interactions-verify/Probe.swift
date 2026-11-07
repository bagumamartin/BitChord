// AppKit dispatches the same mouse/key events that the app's views receive.
// Keep this probe's preferences separate from the listener's BitChord settings.
@MainActor @Observable
final class PlaybackController {
    var toggles = 0
    var previousCalls = 0
    var nextCalls = 0
    func togglePlayPause() { toggles += 1 }
    func previous() { previousCalls += 1 }
    func next() { nextCalls += 1 }
}

@MainActor @Observable
private final class ProbeModel {
    var plays = 0
    var text = "Blue"
}

private struct SearchFixture: View {
    @Bindable var model: ProbeModel
    let controller: PlaybackController
    @FocusState private var focused: Bool

    var body: some View {
        MacToolbarSearchField(text: $model.text, focused: $focused, onSubmit: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .modifier(MacTransportKeys(controller: controller))
    }
}

@main
private struct MacInteractionProbe {
    @MainActor static var failures = 0
    @MainActor static var events = 0

    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        if condition() { print("PASS \(label)") }
        else { fputs("FAIL \(label)\n", stderr); failures += 1 }
    }

    @MainActor static func settle(_ duration: TimeInterval = 0.12) {
        let until = Date(timeIntervalSinceNow: duration)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: until)
        }
    }

    @MainActor static func window<V: View>(_ content: V, preferences: UserDefaults) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content.defaultAppStorage(preferences))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settle()
        return window
    }

    @MainActor static func click(_ window: NSWindow, x: CGFloat = 200, y: CGFloat = 50, count: Int = 1) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            events += 1
            let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: events,
                clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApp.postEvent(event, atStart: false)
            while let queued = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(queued)
            }
        }
        settle()
    }

    @MainActor static func key(_ window: NSWindow, _ characters: String, code: UInt16,
                               modifiers: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!
            NSApp.sendEvent(event)
        }
        settle()
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { runChecks() }
        NSApp.run()
    }

    @MainActor static func runChecks() {
        let suite = "app.bitchord.interaction-tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }

        let model = ProbeModel()
        let sanity = window(Button("Sanity") { model.plays += 1 }
            .frame(maxWidth: .infinity, maxHeight: .infinity), preferences: preferences)
        click(sanity)
        check(model.plays == 1, "fixture delivers mouse events to a native button")
        sanity.close()
        model.plays = 0
        let selection = RowSelection()
        func row() -> some View {
            Text("Song")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(MacRowInteraction(id: "song", play: { model.plays += 1 }, selection: selection))
        }
        let single = window(row(), preferences: preferences)
        let activationClick = NSEvent.mouseEvent(with: .leftMouseDown,
            location: NSPoint(x: 200, y: 50), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: single.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1)!
        check(single.contentView?.hitTest(NSPoint(x: 200, y: 50))?.acceptsFirstMouse(for: activationClick) == true,
              "a song row accepts the click that activates its window")
        click(single)
        settle(NSEvent.doubleClickInterval + 0.1)
        check(model.plays == 1, "one click plays a song with the default preference")
        check(selection.id == "song", "clicking a song also selects it")
        single.close()

        preferences.set(false, forKey: "mac_single_click_play")
        model.plays = 0
        let double = window(row(), preferences: preferences)
        click(double)
        settle(NSEvent.doubleClickInterval + 0.1)
        check(model.plays == 0, "double-click mode keeps a single click as selection")
        click(double)
        click(double, count: 2)
        settle(NSEvent.doubleClickInterval + 0.1)
        check(model.plays == 1, "double-click mode plays once on the second click")
        double.close()

        if failures != 0 { exit(1) }
        print("PASS macOS interaction regressions")
        exit(0)
    }
}
