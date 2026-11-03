// Licensed under GPL-3.0. See LICENSE.
//
//  ExternalLinkDestinationCheck.swift
//  Nook
//
//  Where a link from another app opens: the mini window by default, or a tab in a regular
//  window, in its current space unless that is the Agent space. Air Traffic Control picks the
//  window for such a link the same way.
//
//    swiftc Packages/NookSettings/Sources/NookSettings/ExternalLinkDestination.swift \
//           Packages/NookSettings/Checks/ExternalLinkDestinationCheck.swift -o /tmp/external-link && /tmp/external-link
//

import Foundation

@main
struct ExternalLinkDestinationCheck {
    static func main() {
        precondition(ExternalLinkDestination(stored: nil) == .miniWindow, "a fresh install keeps the mini window")
        precondition(ExternalLinkDestination(stored: "littleArc") == .miniWindow, "an unknown stored value reads as the mini window")
        precondition(ExternalLinkDestination(stored: "currentSpace") == .currentSpace, "the stored choice")

        let front = UUID(), back = UUID(), privateWindow = UUID()
        precondition(ExternalLinkWindow(activeWindow: back, regularWindows: [front, back], windowOpening: false) == .existing(back),
                     "the active regular window, wherever it is in the stack")
        precondition(ExternalLinkWindow(activeWindow: privateWindow, regularWindows: [front, back], windowOpening: false) == .existing(front),
                     "a private window in front: the frontmost regular window instead")
        precondition(ExternalLinkWindow(activeWindow: privateWindow, regularWindows: [], windowOpening: false) == .new,
                     "only private windows open: a new regular window")
        precondition(ExternalLinkWindow(activeWindow: nil, regularWindows: [], windowOpening: false) == .new,
                     "every window closed: a new window")
        precondition(ExternalLinkWindow(activeWindow: nil, regularWindows: [], windowOpening: true) == .opening,
                     "cold launch, or a window already opening: never an extra window")
        let restored = UUID()
        precondition(ExternalLinkWindow(activeWindow: nil, regularWindows: [restored], windowOpening: false) == .existing(restored),
                     "cold launch: the restored window, before it is first made key")

        let work = UUID(), home = UUID(), agent = UUID()
        let spaces = [agent, work, home]
        precondition(ExternalLinkDestination.space(showing: home, spaces: spaces, agentSpace: agent) == home,
                     "the window's current space")
        precondition(ExternalLinkDestination.space(showing: home, spaces: spaces, agentSpace: nil) == home)
        precondition(ExternalLinkDestination.space(showing: agent, spaces: spaces, agentSpace: agent) == work,
                     "never the Agent space: the first other space")
        precondition(ExternalLinkDestination.space(showing: agent, spaces: [agent], agentSpace: agent) == nil,
                     "no space but the Agent space: no tab")
        print("ExternalLinkDestinationCheck passed")
    }
}
