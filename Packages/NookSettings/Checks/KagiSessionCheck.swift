// Licensed under GPL-3.0. See LICENSE.
// swiftc Packages/NookSettings/Sources/NookSettings/KagiSession.swift Packages/NookSettings/Checks/KagiSessionCheck.swift -o /tmp/kagi-session && /tmp/kagi-session

import Foundation

@main
struct KagiSessionCheck {
    static func main() {
        // A pasted Session Link or a bare token both give the token.
        precondition(KagiSession.token(fromPasted: "https://kagi.com/search?token=abc.DEF-1_2&q=%s") == "abc.DEF-1_2")
        precondition(KagiSession.token(fromPasted: "  abc.DEF  ") == "abc.DEF")
        precondition(KagiSession.token(fromPasted: "https://kagi.com/search?q=x") == nil)
        precondition(KagiSession.token(fromPasted: "") == nil)

        // Searches carry the token so every profile is signed in.
        precondition(KagiSession.searchTemplate(token: "a+b/c") == "https://kagi.com/search?token=a%2Bb%2Fc&q=%@")

        // Stored page addresses never keep it; other sites keep their parameters.
        let signed = URL(string: "https://kagi.com/search?token=abc&q=swift")!
        precondition(KagiSession.withoutToken(signed).absoluteString == "https://kagi.com/search?q=swift")
        let plusses = URL(string: "https://kagi.com/search?token=abc&q=c%2B%2B")!
        precondition(KagiSession.withoutToken(plusses).absoluteString == "https://kagi.com/search?q=c%2B%2B", "encoded query survives")
        let other = URL(string: "https://example.com/?token=keep")!
        precondition(KagiSession.withoutToken(other) == other)
        print("KagiSessionCheck passed")
    }
}
