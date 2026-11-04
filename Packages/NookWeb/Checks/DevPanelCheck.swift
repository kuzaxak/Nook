// Licensed under GPL-3.0. See LICENSE.
//
//  DevPanelCheck.swift
//  Nook
//
//  The right column when Developer Mode goes off beside it.
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/DevTools/DevLog.swift \
//           Packages/NookWeb/Sources/NookWeb/DevTools/DevEntries.swift \
//           Packages/NookWeb/Checks/DevPanelCheck.swift -o /tmp/devpanel && /tmp/devpanel
//

import Foundation

@main
struct DevPanelCheck {
    /// One window's right column: open or not, on the tab last picked.
    struct Column {
        var isOpen: Bool
        var chosen: DevPanelTab

        /// A site's Developer Mode, or the one in Settings, going off; `developerMode` is the
        /// Settings one the column was showing under.
        mutating func developerModeOff(developerMode: Bool = true, agent: Bool) {
            isOpen = DevPanelTab.staysOpen(isOpen, showing: DevPanelTab.shown(chosen, developerMode: developerMode, agent: agent))
        }
    }

    static func main() {
        for tool in [DevPanelTab.console, .network, .blocker, .perf] {
            var column = Column(isOpen: true, chosen: tool)
            column.developerModeOff(agent: true)
            precondition(!column.isOpen, "Open on \(tool), the column closes with Developer Mode")
        }

        var agent = Column(isOpen: true, chosen: .agent)
        agent.developerModeOff(agent: true)
        precondition(agent.isOpen, "On the Agent tab it stays")

        var shut = Column(isOpen: false, chosen: .console)
        shut.developerModeOff(agent: true)
        precondition(!shut.isOpen, "A shut column stays shut")

        // With the AI assistant off there is no Agent tab, and a column left on it shows the Console.
        precondition(DevPanelTab.tabs(agent: false) == [.console, .network, .blocker, .perf])
        precondition(DevPanelTab.tabs(agent: true) == DevPanelTab.allCases)
        precondition(DevPanelTab.shown(.agent, developerMode: true, agent: false) == .console)
        precondition(DevPanelTab.shown(.perf, developerMode: true, agent: false) == .perf)
        var hiddenAgent = Column(isOpen: true, chosen: .agent)
        hiddenAgent.developerModeOff(agent: false)
        precondition(!hiddenAgent.isOpen, "Showing the Console in place of a hidden Agent tab, it closes")

        // With Developer Mode off in Settings the column is the AI chat, whatever tab was picked.
        precondition(DevPanelTab.shown(.console, developerMode: false, agent: true) == .agent)
        var chat = Column(isOpen: true, chosen: .console)
        chat.developerModeOff(developerMode: false, agent: true)
        precondition(chat.isOpen, "A site's Developer Mode going off leaves the AI chat open")

        // On and off again: each time off acts on what the column shows then.
        var column = Column(isOpen: true, chosen: .console)
        column.developerModeOff(agent: true)
        precondition(!column.isOpen)
        column = Column(isOpen: true, chosen: .agent)
        column.developerModeOff(agent: true)
        column.developerModeOff(agent: true)
        precondition(column.isOpen && column.chosen == .agent)
        column.chosen = .network
        column.developerModeOff(agent: true)
        precondition(!column.isOpen)
        print("DevPanelCheck passed")
    }
}
