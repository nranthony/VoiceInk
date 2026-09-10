import Foundation
import AppKit
import Carbon
import os

/// Lets two racing callbacks share one continuation: the first to claim wins, the loser is a no-op.
private final class OneShotResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isResolved else { return false }
        isResolved = true
        return true
    }
}

class CursorPaster {
    private typealias ClipboardItemSnapshot = [(NSPasteboard.PasteboardType, Data)]
    private typealias ClipboardSnapshot = [ClipboardItemSnapshot]
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CursorPaster")

    // Serial so a wedged snapshot cannot pile up threads across pastes; a later snapshot simply
    // queues behind it and gives up on its own timeout.
    private static let clipboardSnapshotQueue = DispatchQueue(
        label: "com.prakashjoshipax.voiceink.clipboardSnapshot",
        qos: .userInitiated
    )
    private static let clipboardSnapshotTimeout: TimeInterval = 2.0

    enum PasteResult: Equatable {
        case commandPosted
        case commandNotPosted

        var didPostPasteCommand: Bool {
            self == .commandPosted
        }
    }

    private static let prePasteDelay: TimeInterval = 0.10
    private static let pasteShortcutEventDelay: TimeInterval = 0.01
    private static let minimumClipboardRestoreDelay: TimeInterval = 0.25
    private static let typeCharacterDelay: TimeInterval = 0.004

    static func pasteAtCursor(_ text: String) {
        Task {
            let pasteTask = await MainActor.run {
                startPasteAtCursor(text)
            }
            _ = await pasteTask.value
        }
    }

    @MainActor
    @discardableResult
    static func startPasteAtCursor(_ text: String) -> Task<PasteResult, Never> {
        Task { @MainActor in
            await performPasteSession(text)
        }
    }

    @MainActor
    static func pasteAtCursorAndWaitUntilPosted(_ text: String) async -> PasteResult {
        await startPasteAtCursor(text).value
    }

    @MainActor
    private static func performPasteSession(_ text: String) async -> PasteResult {
        let pasteboard = NSPasteboard.general
        let method = PasteMethod.current()
        let shouldRestoreClipboard = UserDefaults.standard.bool(forKey: "restoreClipboardAfterPaste")

        // `typeCharacters` posts the text as Unicode key events, so the clipboard is not the
        // transport for it. With restore enabled the snapshot/set/restore round trip ends exactly
        // where it started — pure work, plus a window where the user's clipboard is clobbered.
        if method == .typeCharacters, shouldRestoreClipboard {
            return await postPasteCommand(text, using: method)
        }

        // nil means "no usable snapshot": either restore is off, or the pasteboard did not answer
        // in time. Restoring from a snapshot we failed to take would wipe the clipboard, so both
        // cases skip the restore.
        var savedContents: ClipboardSnapshot?
        if shouldRestoreClipboard {
            savedContents = await snapshotClipboard(timeout: clipboardSnapshotTimeout)
        }

        let willRestoreClipboard = savedContents != nil
        let sessionID = UUID().uuidString

        guard ClipboardManager.setClipboard(
            text,
            transient: willRestoreClipboard,
            sessionID: willRestoreClipboard ? sessionID : nil
        ) else {
            logger.error("Failed to prepare clipboard for paste")
            return .commandNotPosted
        }

        await wait(prePasteDelay)

        let pasteResult = await postPasteCommand(text, using: method)
        if let savedContents {
            scheduleClipboardRestore(
                savedContents,
                expectedText: text,
                sessionID: sessionID,
                on: pasteboard
            )
        }

        return pasteResult
    }

    // Reading an item's data off NSPasteboard is a synchronous IPC to the pasteboard server, and
    // the owning app supplies the payload lazily. When the owner is a remote/VM client — Windows
    // App over RDP only fetches from the guest on demand — that IPC blocks until the server's ~60s
    // timeout. On the main actor that freezes the whole app *after* transcription: the mini
    // recorder stays up and the transcript pastes a minute late, into whatever window has focus by
    // then. So take the snapshot off the main thread and give up early; a paste that loses the
    // previous clipboard is far better than one that arrives a minute late in the wrong window.
    private static func snapshotClipboard(timeout: TimeInterval) async -> ClipboardSnapshot? {
        let resolver = OneShotResolver()

        return await withCheckedContinuation { (continuation: CheckedContinuation<ClipboardSnapshot?, Never>) in
            clipboardSnapshotQueue.async {
                let snapshot = readClipboard()
                if resolver.claim() {
                    continuation.resume(returning: snapshot)
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if resolver.claim() {
                    logger.notice("Clipboard snapshot timed out after \(timeout, format: .fixed(precision: 1), privacy: .public)s – pasting without preserving the previous clipboard")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func readClipboard() -> ClipboardSnapshot {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                if let data = item.data(forType: type) {
                    return (type, data)
                }
                return nil
            }
        }
    }

    @MainActor
    private static func postPasteCommand(_ text: String, using method: PasteMethod) async -> PasteResult {
        switch method {
        case .appleScript:
            return pasteUsingAppleScript() ? .commandPosted : .commandNotPosted
        case .controlV:
            return await pasteUsingControlV()
        case .typeCharacters:
            return await typeText(text)
        case .standard:
            return await pasteFromClipboard()
        }
    }

    private static func scheduleClipboardRestore(
        _ savedContents: ClipboardSnapshot,
        expectedText: String,
        sessionID: String,
        on pasteboard: NSPasteboard
    ) {
        let delay = max(
            UserDefaults.standard.double(forKey: "clipboardRestoreDelay"),
            minimumClipboardRestoreDelay
        )

        Task { @MainActor in
            await wait(delay)
            guard pasteboardStillOwnedByPasteSession(pasteboard, expectedText: expectedText, sessionID: sessionID) else {
                return
            }
            pasteboard.clearContents()
            if !savedContents.isEmpty {
                pasteboard.writeObjects(pasteboardItems(from: savedContents))
            }
        }
    }

    private static func pasteboardStillOwnedByPasteSession(
        _ pasteboard: NSPasteboard,
        expectedText: String,
        sessionID: String
    ) -> Bool {
        pasteboard.string(forType: .string) == expectedText &&
            pasteboard.string(forType: ClipboardManager.pasteSessionType) == sessionID
    }

    private static func pasteboardItems(from snapshot: ClipboardSnapshot) -> [NSPasteboardItem] {
        snapshot.map { itemSnapshot in
            let item = NSPasteboardItem()
            for (type, data) in itemSnapshot {
                item.setData(data, forType: type)
            }
            return item
        }
    }

    // MARK: - AppleScript paste

    // "X – QWERTY ⌘" layouts remap to QWERTY when Command is held, so keystroke "v" resolves
    // the wrong key code. key code 9 (physical V) bypasses layout translation for those layouts.
    private static func makeScript(_ source: String) -> NSAppleScript? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        script?.compileAndReturnError(&error)
        return script
    }

    private static let pasteScriptKeystroke = makeScript("tell application \"System Events\" to keystroke \"v\" using command down")
    private static let pasteScriptKeyCode   = makeScript("tell application \"System Events\" to key code 9 using command down")

    @MainActor
    private static var layoutSwitchesToQWERTYOnCommand: Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return false }
        return (Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String).hasSuffix("⌘")
    }

    @MainActor
    private static func pasteUsingAppleScript() -> Bool {
        guard let script = layoutSwitchesToQWERTYOnCommand ? pasteScriptKeyCode : pasteScriptKeystroke else {
            logger.error("AppleScript paste script is unavailable")
            return false
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            logger.error("AppleScript paste failed: \(String(describing: error), privacy: .public)")
        }
        return error == nil
    }

    // MARK: - CGEvent paste

    // Posts Cmd+V via CGEvent without modifying the active input source.
    @MainActor
    private static func pasteFromClipboard() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            logger.error("Failed to create Cmd+V keyboard events")
            return .commandNotPosted
        }

        cmdDown.flags = .maskCommand
        vDown.flags   = .maskCommand
        vUp.flags     = .maskCommand

        cmdDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        cmdUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    // MARK: - Windows / VM paste (Ctrl+V)

    // Posts Ctrl+V instead of Cmd+V. Windows apps running in a VM / over RDP use Ctrl+V to
    // paste, and the guest typically receives the Mac's Control modifier intact (whereas Command
    // does not map and the focused window only sees the bare "V" character).
    @MainActor
    private static func pasteUsingControlV() async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to paste with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        guard let ctrlDown = CGEvent(keyboardEventSource: source, virtualKey: 0x3B, keyDown: true),
              let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let ctrlUp = CGEvent(keyboardEventSource: source, virtualKey: 0x3B, keyDown: false) else {
            logger.error("Failed to create Ctrl+V keyboard events")
            return .commandNotPosted
        }

        ctrlDown.flags = .maskControl
        vDown.flags    = .maskControl
        vUp.flags      = .maskControl

        ctrlDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vDown.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        vUp.post(tap: .cghidEventTap)
        await wait(pasteShortcutEventDelay)
        ctrlUp.post(tap: .cghidEventTap)

        return .commandPosted
    }

    // MARK: - Direct typing

    // Types the text character-by-character as Unicode key events, bypassing the clipboard and
    // any paste shortcut entirely. Works even when clipboard sharing between the Mac and a VM/RDP
    // session is disabled, at the cost of being slower for long text.
    //
    // The events carry the character via keyboardSetUnicodeString with virtualKey 0, so the RDP/VM
    // client must be in Unicode keyboard mode (e.g. Windows App → Keyboard → Unicode). In Scan code
    // mode the client reads the virtual key instead of the Unicode payload — virtualKey 0 is the
    // physical "A" key, so every character arrives as "A".
    @MainActor
    private static func typeText(_ text: String) async -> PasteResult {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to type text with simulated key events")
            return .commandNotPosted
        }

        let source = CGEventSource(stateID: .privateState)

        for character in text {
            let utf16 = Array(String(character).utf16)
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                continue
            }

            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            await wait(typeCharacterDelay)
        }

        return .commandPosted
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: - Auto Send Keys

    static func performAutoSend(_ key: AutoSendKey) {
        guard key.isEnabled else { return }
        guard AXIsProcessTrusted() else { return }

        let source = CGEventSource(stateID: .privateState)
        let enterDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let enterUp   = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)

        switch key {
        case .none: return
        case .enter: break
        case .shiftEnter:
            enterDown?.flags = .maskShift
            enterUp?.flags   = .maskShift
        case .commandEnter:
            enterDown?.flags = .maskCommand
            enterUp?.flags   = .maskCommand
        }

        enterDown?.post(tap: .cghidEventTap)
        enterUp?.post(tap: .cghidEventTap)
    }
}
