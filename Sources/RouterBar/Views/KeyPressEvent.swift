import AppKit

/// What a page's onKeyPress filter sees of an edit: the character of the key press the app is handling. A text field
/// changes its text inside that key press (NSApp.currentEvent is its keyDown), and inside a ⌘V or a menu's Paste for a
/// paste, which the filters let through as the browser does. Deleting, moving and other keys type nothing.
enum KeyPressEvent {
    @MainActor static var typedCharacter: Character? {
        guard let event = NSApp.currentEvent, event.type == .keyDown, !event.modifierFlags.contains(.command),
              let characters = event.characters, characters.count == 1, let character = characters.first,
              let scalar = character.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value) else { return nil }
        return character
    }

    /// The last change of characters in a text storage, as the field editor's storage reports it while a text field is
    /// edited: that storage, the range that now holds what went in, and how much longer the text became.
    private final class StorageEdit {
        weak var storage: NSTextStorage?
        let range: NSRange, change: Int
        init(_ storage: NSTextStorage, range: NSRange, change: Int) { self.storage = storage; self.range = range; self.change = change }
    }
    @MainActor private static var lastEdit: StorageEdit?
    @MainActor private static var observer: NSObjectProtocol?

    /// Starts noting the edits of text storages made on the main thread (as a field editor's are); called once at launch.
    /// The note is taken while the storage still holds the edit's range; the text itself is read only when a field asks.
    @MainActor static func startTracking() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: nil,
                                                          queue: nil) { note in
            guard Thread.isMainThread, let storage = note.object as? NSTextStorage,
                  storage.editedMask.contains(.editedCharacters) else { return }
            let range = storage.editedRange, change = storage.changeInLength
            nonisolated(unsafe) let edited = storage
            MainActor.assumeIsolated { lastEdit = StorageEdit(edited, range: range, change: change) }
        }
    }

    /// The part of `old` (UTF-16 offsets) that the edit which made it into `new` replaced, when the last edit the field
    /// editor reported is that edit (its storage still holds `new`); nil otherwise (WebValidator.edit then works it out
    /// from the two texts).
    @MainActor static func replacedRange(_ old: String, _ new: String) -> Range<Int>? {
        guard let edit = lastEdit, let storage = edit.storage, storage.length == new.utf16.count,
              old.utf16.count + edit.change == new.utf16.count, edit.range.location != NSNotFound,
              edit.range.length >= edit.change, storage.string == new else { return nil }
        return edit.range.location..<(edit.range.location + edit.range.length - edit.change)
    }
}
