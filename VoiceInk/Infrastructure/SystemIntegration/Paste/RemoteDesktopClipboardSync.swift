import AppKit
import ApplicationServices
import Darwin
import os
import UniformTypeIdentifiers

/// FreeRDP's SDL3 client only reads the Mac clipboard when its window becomes key
/// (SDL_cocoawindow.m `windowDidBecomeKey` → `Cocoa_CheckClipboardUpdate`), so text written to the
/// clipboard while it stays frontmost never reaches the remote session. Moving focus away and back
/// makes SDL announce the new clipboard to the server before Cmd+V is posted.
enum RemoteDesktopClipboardSync {
    private static let logger = Logger(
        subsystem: "com.prakashjoshipax.voiceink", category: "RemoteDesktopClipboardSync")

    // Homebrew FreeRDP only: /opt/homebrew/bin/sdl-freerdp resolves into the Cellar, and a client
    // started before a `brew upgrade` keeps running from its old Cellar version.
    private static let clientCellarPrefix = "/opt/homebrew/Cellar/freerdp/"
    private static let clientExecutableSuffix = "/bin/sdl-freerdp"

    // FreeRDP tags clipboard contents it received from the server with this MIME type (plus a
    // per-session UUID). A local clipboard carrying it is treated as FreeRDP's own server data:
    // its change is never announced and server requests for it are refused.
    private static let clientOwnershipMIMEPrefix = "x-special/freerdp-clipboard-update"

    // Hidden tuning knobs: `defaults write com.prakashjoshipax.VoiceInk <key> <value>`.
    private enum DefaultsKey {
        /// "finder" (the default) or any running app's bundle ID. VoiceInk itself cannot be the target:
        /// macOS 14+ refuses activation requests from a background app.
        static let focusTarget = "rdpFocusTarget"
        static let focusAwayDelay = "rdpFocusAwayDelay"
        static let clipboardSyncDelay = "rdpClipboardSyncDelay"
        static let minimumRestoreDelay = "rdpMinimumClipboardRestoreDelay"
    }

    private static let focusChangeTimeout: TimeInterval = 1.0
    private static let keyboardIdleInterval: TimeInterval = 0.5
    /// Past this the restore is left for SDL to pick up on the client's next focus change.
    private static let keyboardIdleTimeout: TimeInterval = 10.0

    struct Client {
        let processIdentifier: pid_t
        let application: NSRunningApplication
    }

    /// Clipboard restore must not run before the remote app has fetched the pasted text.
    static var minimumClipboardRestoreDelay: TimeInterval {
        setting(DefaultsKey.minimumRestoreDelay, default: 2.0)
    }

    @MainActor
    static func frontmostClient() -> Client? {
        guard let application = NSWorkspace.shared.frontmostApplication,
            let path = executablePath(of: application.processIdentifier),
            path.hasPrefix(clientCellarPrefix), path.hasSuffix(clientExecutableSuffix)
        else {
            return nil
        }
        return Client(processIdentifier: application.processIdentifier, application: application)
    }

    /// Bounces focus away from the client and back. Returns true only when the same client process
    /// is frontmost again after the sync delay, so Cmd+V cannot land in another app.
    @MainActor
    static func syncClipboard(to client: Client, sessionID: String) async -> Bool {
        let clientPID = client.processIdentifier
        let target = UserDefaults.standard.string(forKey: DefaultsKey.focusTarget) ?? "finder"

        guard activateFocusTarget(target, excluding: clientPID),
            await waitUntil({ frontmostPID() != clientPID }, timeout: focusChangeTimeout)
        else {
            logger.error(
                "RDP clipboard sync: could not move focus away target=\(target, privacy: .public) id=\(sessionID, privacy: .public)"
            )
            return false
        }

        await wait(setting(DefaultsKey.focusAwayDelay, default: 0.10))

        guard activate(pid: clientPID, application: client.application),
            await waitUntil({ frontmostPID() == clientPID }, timeout: focusChangeTimeout)
        else {
            logger.error("RDP clipboard sync: could not refocus client id=\(sessionID, privacy: .public)")
            return false
        }

        await wait(setting(DefaultsKey.clipboardSyncDelay, default: 0.40))

        guard frontmostPID() == clientPID else {
            logger.error("RDP clipboard sync: focus moved before paste id=\(sessionID, privacy: .public)")
            return false
        }

        logger.notice("RDP clipboard sync: refocused client target=\(target, privacy: .public) id=\(sessionID, privacy: .public)")
        return true
    }

    /// Restoring the clipboard after a paste is another change SDL only sees on refocus; without
    /// announcing it, the remote session keeps the transcript instead of what was copied before.
    @MainActor
    static func announceRestoredClipboard(to client: Client, sessionID: String) async {
        // Not frontmost: SDL picks the restored clipboard up when its window next becomes key.
        guard frontmostPID() == client.processIdentifier else { return }

        guard await waitUntil({ isKeyboardIdle() }, timeout: keyboardIdleTimeout) else {
            logger.notice("RDP clipboard sync: keyboard busy, restore not announced id=\(sessionID, privacy: .public)")
            return
        }
        guard frontmostPID() == client.processIdentifier else { return }
        _ = await syncClipboard(to: client, sessionID: sessionID)
    }

    /// SDL releases every key when its window loses focus and does not see a modifier that is still
    /// held when focus returns, so a Cmd+V pressed across a focus bounce reaches the remote as a bare
    /// "v". Bounce only once no modifier is held and the keyboard has been quiet for a moment.
    private static func isKeyboardIdle() -> Bool {
        let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        guard CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            return false
        }
        return [CGEventType.keyDown, .flagsChanged].allSatisfy {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= keyboardIdleInterval
        }
    }

    /// SDL exposes MIME types on the Mac pasteboard as (usually dynamic) UTIs.
    static func isClientOwnershipMarker(_ type: NSPasteboard.PasteboardType) -> Bool {
        let mimeType = UTType(type.rawValue)?.preferredMIMEType ?? type.rawValue
        return mimeType.hasPrefix(clientOwnershipMIMEPrefix)
    }

    @MainActor
    private static func activateFocusTarget(_ target: String, excluding clientPID: pid_t) -> Bool {
        let bundleID = target == "finder" ? "com.apple.finder" : target
        guard
            let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != clientPID })
        else {
            return false
        }
        return activate(pid: application.processIdentifier, application: application)
    }

    /// Accessibility works even when VoiceInk is not the active app; `activate` is the fallback.
    @MainActor
    private static func activate(pid: pid_t, application: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        if AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success {
            return true
        }
        return application.activate()
    }

    @MainActor
    private static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    @MainActor
    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                return false
            }
            await wait(0.02)
        }
        return true
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func setting(_ key: String, default defaultValue: TimeInterval) -> TimeInterval {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return defaultValue
        }
        return min(max(UserDefaults.standard.double(forKey: key), 0), 3.0)
    }

    private static func wait(_ seconds: TimeInterval) async {
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
