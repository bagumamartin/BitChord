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

private struct RowsFixture: View {
    let model: ProbeModel
    let selection: RowSelection
    let controller: PlaybackController
    var includesWindowTransport = true

    var body: some View {
        if includesWindowTransport {
            rows.modifier(MacTransportKeys(controller: controller))
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(["first", "second"], id: \.self) { id in
                Text(id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(MacRowInteraction(id: id, play: { model.plays += 1 }, selection: selection))
            }
        }
        .rowKeyboardNavigation(ids: ["first", "second"])
        .environment(\.rowSelection, selection)
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
            _ = RunLoop.current.run(mode: .default, before: until)
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
                               modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: repeating && type == .keyDown, keyCode: code)!
            NSApp.sendEvent(event)
        }
        settle()
    }

    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { exit(runChecks()) }
        NSApp.run()
    }

    @MainActor static func runChecks() -> Int32 {
        let suite = "app.bitchord.interaction-tests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer {
            preferences.removePersistentDomain(forName: suite)
            preferences.synchronize()
        }

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

        // Changing Settings updates rows already on screen, and a new window
        // reads the same persisted value rather than resetting the preference.
        let live = window(row(), preferences: preferences)
        preferences.set(true, forKey: "mac_single_click_play")
        settle()
        model.plays = 0
        click(live)
        settle(NSEvent.doubleClickInterval + 0.1)
        check(model.plays == 1, "changing the preference updates an existing row")
        live.close()
        let reopened = window(row(), preferences: preferences)
        model.plays = 0
        click(reopened)
        settle(NSEvent.doubleClickInterval + 0.1)
        check(model.plays == 1, "a new window retains the saved single-click preference")
        reopened.close()

        let keyboardSelection = RowSelection()
        let keyboardController = PlaybackController()
        let keyboard = window(RowsFixture(model: model, selection: keyboardSelection,
            controller: keyboardController), preferences: preferences)
        keyboard.becomeKey()
        click(keyboard, y: 75)
        check(keyboardSelection.id == "first", "the keyboard fixture selects and focuses its first row")
        let beforeReturn = model.plays
        key(keyboard, "\r", code: 36)
        check(model.plays == beforeReturn + 1, "Return activates the focused song row once")
        let beforeSpace = model.plays
        key(keyboard, " ", code: 49)
        check(model.plays == beforeSpace && keyboardController.toggles == 1,
              "window Space toggles playback once without also restarting the row")
        let beforeRepeat = model.plays
        key(keyboard, " ", code: 49, repeating: true)
        check(model.plays == beforeRepeat && keyboardController.toggles == 1,
              "held Space does not restart the row or toggle transport repeatedly")
        key(keyboard, " ", code: 49, modifiers: .command)
        check(model.plays == beforeRepeat && keyboardController.toggles == 1,
              "modified Space is left for its own command")
        key(keyboard, String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125)
        check(keyboardSelection.id == "second", "Down moves selection to the next song")
        key(keyboard, String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126)
        check(keyboardSelection.id == "first", "Up moves selection to the previous song")
        check(model.plays == beforeRepeat, "arrow navigation selects without starting playback")
        keyboard.close()

        let isolatedSelection = RowSelection()
        let isolated = window(RowsFixture(model: model, selection: isolatedSelection,
            controller: keyboardController, includesWindowTransport: false), preferences: preferences)
        isolated.becomeKey()
        click(isolated, y: 75)
        let beforeIsolated = model.plays
        key(isolated, " ", code: 49)
        check(model.plays == beforeIsolated + 1, "standalone row Space activates playback once")
        key(isolated, " ", code: 49, repeating: true)
        check(model.plays == beforeIsolated + 1, "standalone row ignores repeated Space")
        key(isolated, "\r", code: 36, modifiers: .shift)
        check(model.plays == beforeIsolated + 1, "standalone row leaves modified Return alone")
        isolated.close()

        let controller = PlaybackController()
        let search = window(SearchFixture(model: model, controller: controller), preferences: preferences)
        search.becomeKey()
        click(search, x: 190)
        check(search.firstResponder is NSTextView, "search fixture acquires its native field editor")
        key(search, " ", code: 49)
        check(model.text.contains(" "), "Space inserts text in the production search field")
        check(controller.toggles == 0, "typing Space in search leaves playback alone")
        key(search, String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123)
        key(search, String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124)
        check(controller.previousCalls == 0 && controller.nextCalls == 0,
              "search cursor arrows leave the playback queue alone")
        search.close()

        if failures != 0 { return 1 }
        print("PASS macOS interaction regressions")
        return 0
    }
}
