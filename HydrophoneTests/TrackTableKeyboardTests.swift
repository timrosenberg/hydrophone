import AppKit
import SwiftUI
import Testing
@testable import Hydrophone

/// Keyboard routing at the AppKit track-table boundary (issue #56).
@MainActor
struct TrackTableKeyboardTests {
    /// SwiftUI/AppKit schedules view teardown after the test body returns. Keep
    /// the single offscreen host alive for the lifetime of the test process so
    /// that teardown cannot race Swift Testing's concurrent main-actor jobs.
    private static var retainedWindows: [NSWindow] = []

    private func descendant<T: NSView>(ofType type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { descendant(ofType: type, in: $0) }.first
    }

    private func keyEvent(
        code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    @Test func spaceInvokesOnlyThePlaybackCallback() {
        let table = InnerTableView()
        var returnCount = 0
        var spaceCount = 0
        table.onReturn = { returnCount += 1 }
        table.onSpace = { spaceCount += 1 }

        table.keyDown(with: keyEvent(code: 49, characters: " "))

        #expect(spaceCount == 1)
        #expect(returnCount == 0)
    }

    @Test(arguments: [UInt16(36), UInt16(76)])
    func returnAndEnterKeepTheirExistingRoute(code: UInt16) {
        let table = InnerTableView()
        var returnCount = 0
        var spaceCount = 0
        table.onReturn = { returnCount += 1 }
        table.onSpace = { spaceCount += 1 }

        table.keyDown(with: keyEvent(code: code, characters: "\r"))

        #expect(returnCount == 1)
        #expect(spaceCount == 0)
    }

    @Test(arguments: [false, true])
    func commandIOpensInfoRegardlessOfCapsLock(capsLock: Bool) {
        let table = InnerTableView()
        var infoCount = 0
        table.onGetInfo = { infoCount += 1 }

        table.keyDown(with: keyEvent(
            code: 34, characters: capsLock ? "I" : "i",
            modifiers: capsLock ? [.command, .capsLock] : .command
        ))

        #expect(infoCount == 1)
    }

    @Test(arguments: [
        NSEvent.ModifierFlags(), .capsLock,
        [.command, .shift], [.command, .option], [.command, .control],
        [.command, .capsLock, .shift], [.command, .capsLock, .option],
        [.command, .capsLock, .control]
    ])
    func otherIModifiersDoNotOpenInfo(modifiers: NSEvent.ModifierFlags) {
        let table = InnerTableView()
        var infoCount = 0
        table.onGetInfo = { infoCount += 1 }

        table.keyDown(with: keyEvent(code: 34, characters: "i", modifiers: modifiers))

        #expect(infoCount == 0)
    }

    @Test func swiftUIListRoutesSpaceToPlayback() {
        var spaceCount = 0
        let list = List { Text("Focusable row") }
            .playPauseOnSpace { spaceCount += 1 }
            .frame(width: 240, height: 160)
        let host = NSHostingView(rootView: list)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        Self.retainedWindows.append(window)

        guard let table = descendant(ofType: NSTableView.self, in: host) else {
            Issue.record("Expected SwiftUI List to host an NSTableView")
            return
        }
        #expect(window.makeFirstResponder(table))

        window.sendEvent(keyEvent(code: 49, characters: " "))

        #expect(spaceCount == 1)
    }
}
