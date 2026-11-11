#if os(macOS)
import AppKit

/// SwiftUI focus can lag behind the toolbar's AppKit field editor. Bare player
/// keys must leave that editor alone, including search, playlist names and sheets.
enum MacKeyboardInput {
    @MainActor static var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        if let editor = responder as? NSTextView { return editor.isEditable }
        if let field = responder as? NSTextField { return field.isEditable }
        return false
    }
}
#endif
