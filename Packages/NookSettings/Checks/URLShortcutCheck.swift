// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookSettings/Sources/NookSettings/URLShortcut.swift Packages/NookSettings/Checks/URLShortcutCheck.swift -o /tmp/url-shortcut && /tmp/url-shortcut

import Foundation

@main
struct URLShortcutCheck {
    static func main() {
        let shortcuts = URLShortcut.defaults + [URLShortcut(keyword: "jira", template: "https://glia.atlassian.net/browse/%@")]
        precondition(URLShortcut.expand("gh glia/infra", in: shortcuts)?.absoluteString == "https://github.com/glia/infra")
        precondition(URLShortcut.expand("GH  glia/infra ", in: shortcuts)?.absoluteString == "https://github.com/glia/infra")
        precondition(URLShortcut.expand("jira OPS-12", in: shortcuts)?.absoluteString == "https://glia.atlassian.net/browse/OPS-12")
        precondition(URLShortcut.expand("gh issues for x", in: shortcuts)?.absoluteString == "https://github.com/issues%20for%20x")
        precondition(URLShortcut.expand("gh", in: shortcuts) == nil, "a keyword needs its argument")
        precondition(URLShortcut.expand("gh ", in: shortcuts) == nil)
        precondition(URLShortcut.expand("ghost story", in: shortcuts) == nil)
        print("URLShortcutCheck passed")
    }
}
