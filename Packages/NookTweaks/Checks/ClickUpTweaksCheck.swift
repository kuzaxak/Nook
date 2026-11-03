// Licensed under GPL-3.0. See LICENSE.
//
//  ClickUpTweaksCheck.swift
//  Nook
//
//  On ClickUp, the chat style's two mention rules lose the selector that made WebKit restyle the
//  whole page for every inserted row, keep highlighting the mention, and leave every other rule
//  alone; other sites keep the style as written. Runs an offscreen WKWebView. From the repo root:
//
//    mkdir -p /tmp/clickup-tweaks && swiftc -parse-as-library -emit-library -static -emit-module \
//           -module-name NookBlocker -emit-module-path /tmp/clickup-tweaks/NookBlocker.swiftmodule \
//           Packages/NookBlocker/Sources/NookBlocker/WKUserScript+NookOwned.swift -o /tmp/clickup-tweaks/libNookBlocker.a && \
//    swiftc -parse-as-library -I /tmp/clickup-tweaks -L /tmp/clickup-tweaks -lNookBlocker \
//           Packages/NookTweaks/Sources/NookTweaks/ClickUpTweaks.swift Packages/NookTweaks/Checks/ClickUpTweaksCheck.swift \
//           -o /tmp/clickup-tweaks/check && /tmp/clickup-tweaks/check
//

import AppKit
import NookBlocker
import WebKit

@MainActor
final class Loader: NSObject, WKNavigationDelegate {
    private var finished: CheckedContinuation<Void, Never>?

    func load(_ html: String, at url: URL, in web: WKWebView) async {
        await withCheckedContinuation { finished = $0; web.loadHTMLString(html, baseURL: url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished?.resume()
        finished = nil
    }
}

@main
struct ClickUpTweaksCheck {
    static let mentionRule = "._message_ndob8_38:not([data-variant=minimal],._PostModalPage_ndob8_39,._threadParent_ndob8_40)"
        + ":has(.cu-mention_me:not(cu-chat-comment-embed *))::after"
    static let threadRule = "._message_ndob8_38:not([data-variant=minimal],._PostModalPage_ndob8_39)"
        + ":has(.cu-mention_me:not(cu-chat-comment-embed *))._threadParentExpandedThread_ndob8_55::after"

    static let headStyle = """
    \(mentionRule) { content: ""; background-color: rgb(1, 2, 3); }
    .row:has(.cu-mention_me) { color: rgb(4, 5, 6); }
    .row { padding: 1px; }
    .embed-only:not(cu-chat-comment-embed *) { margin: 1px; }
    """
    static let chatModuleStyle = """
    \(threadRule) { content: ""; background-color: rgb(7, 8, 9); }
    @media all { \(mentionRule) { content: ""; background-color: rgb(1, 2, 3); } }
    """

    static let page = """
    <!doctype html><html><head><style>\(headStyle)</style></head><body>
    <div id=mention class=_message_ndob8_38><span class=cu-mention_me>@me</span></div>
    <div id=plain class=_message_ndob8_38><span>hi</span></div>
    <style>\(threadRule) { content: ""; background-color: rgb(7, 8, 9); }</style>
    \(String(repeating: "<div class=row><span>row</span></div>", count: 5000))
    </body></html>
    """

    static let original = [
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39, ._threadParent_ndob8_40):has(.cu-mention_me:not(cu-chat-comment-embed *))::after"#,
        ".row:has(.cu-mention_me)",
        ".row",
        ".embed-only:not(cu-chat-comment-embed *)",
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39):has(.cu-mention_me:not(cu-chat-comment-embed *))._threadParentExpandedThread_ndob8_55::after"#,
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39, ._threadParent_ndob8_40):has(.cu-mention_me:not(cu-chat-comment-embed *))::after"#,
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39):has(.cu-mention_me:not(cu-chat-comment-embed *))._threadParentExpandedThread_ndob8_55::after"#,
    ]
    static let rewritten = [
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39, ._threadParent_ndob8_40):has(.cu-mention_me)::after"#,
        ".row:has(.cu-mention_me)",
        ".row",
        ".embed-only:not(cu-chat-comment-embed *)",
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39):has(.cu-mention_me)._threadParentExpandedThread_ndob8_55::after"#,
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39, ._threadParent_ndob8_40):has(.cu-mention_me)::after"#,
        #"._message_ndob8_38:not([data-variant="minimal"], ._PostModalPage_ndob8_39):has(.cu-mention_me)._threadParentExpandedThread_ndob8_55::after"#,
    ]

    static let selectorsJS = """
    (function () {
      var out = [];
      function walk(rules) {
        for (var i = 0; i < rules.length; i++) {
          if (rules[i].selectorText !== undefined) out.push(rules[i].selectorText);
          if (rules[i].cssRules) walk(rules[i].cssRules);
        }
      }
      for (var i = 0; i < document.styleSheets.length; i++) walk(document.styleSheets[i].cssRules);
      return JSON.stringify(out);
    })()
    """
    static let msPerChangeJS = """
    document.body.offsetHeight;
    var start = performance.now();
    for (var i = 0; i < 100; i++) { var row = document.createElement('div'); document.body.appendChild(row); row.remove(); }
    String((performance.now() - start) / 100)
    """

    struct Loaded {
        let selectors: [String]
        let msPerChange: Double
        let mentionAfter: String
        let plainAfter: String
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { fatalError("ClickUpTweaksCheck timed out") }

        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = web
        window.orderBack(nil)
        let loader = Loader()
        web.navigationDelegate = loader
        let ucc = web.configuration.userContentController
        ucc.addUserScript(WKUserScript(source: "// Nook Other\n", injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let clickUp = URL(string: "https://app.clickup.com/t/86c0abcde")!
        let other = URL(string: "https://example.com/")!

        func js(_ source: String) async -> String {
            do {
                guard let result = try await web.evaluateJavaScript(source) as? String else { fatalError("not a string: \(source)") }
                return result
            } catch {
                fatalError("script failed: \(error)")
            }
        }
        func load(at url: URL) async -> Loaded {
            await loader.load(page, at: url, in: web)
            _ = await js("""
            document.head.appendChild(document.createElement('style')).appendChild(document.createTextNode(\(jsString(chatModuleStyle)))); ''
            """)
            let selectors = try! JSONDecoder().decode([String].self, from: Data(await js(selectorsJS).utf8))
            let ms = Double(await js(msPerChangeJS))!
            let mention = await js("getComputedStyle(document.getElementById('mention'), '::after').backgroundColor")
            let plain = await js("getComputedStyle(document.getElementById('plain'), '::after').backgroundColor")
            return Loaded(selectors: selectors, msPerChange: ms, mentionAfter: mention, plainAfter: plain)
        }
        func clickUpScripts() -> Int { ucc.userScripts.filter { $0.source.hasPrefix("// Nook ClickUp Tweaks") }.count }
        func keepsOther() -> Bool { ucc.userScripts.contains { $0.source.hasPrefix("// Nook Other") } }

        Task { @MainActor in
            ClickUpTweaks.apply(for: clickUp, in: web)
            ClickUpTweaks.apply(for: clickUp, in: web)
            precondition(clickUpScripts() == 1 && keepsOther(), "one ClickUp script, others kept: \(ucc.userScripts.map(\.source))")
            precondition(ucc.userScripts.first { $0.source.hasPrefix("// Nook ClickUp Tweaks") }!.isNookOwned,
                         "other tweaks re-add only Nook-owned scripts after removeAllUserScripts")

            let tweaked = await load(at: clickUp)
            precondition(tweaked.selectors == rewritten, "ClickUp selectors: \(tweaked.selectors)")
            precondition(tweaked.mentionAfter == "rgb(1, 2, 3)", "mention highlight lost: \(tweaked.mentionAfter)")
            precondition(tweaked.plainAfter != "rgb(1, 2, 3)", "highlight without a mention: \(tweaked.plainAfter)")

            let unguarded = await load(at: other)
            precondition(unguarded.selectors == original, "script left in a shared controller ran off ClickUp: \(unguarded.selectors)")

            ClickUpTweaks.apply(for: other, in: web)
            precondition(clickUpScripts() == 0 && keepsOther(), "ClickUp script removed off ClickUp, others kept: \(ucc.userScripts.map(\.source))")
            let untweaked = await load(at: other)
            precondition(untweaked.selectors == original, "other site selectors: \(untweaked.selectors)")

            precondition(untweaked.msPerChange > 0 && untweaked.msPerChange >= 5 * tweaked.msPerChange,
                         "insert+remove on 10,000 elements: \(tweaked.msPerChange) ms tweaked, \(untweaked.msPerChange) ms as written")
            print("ClickUpTweaksCheck passed: \(tweaked.msPerChange) ms per row change tweaked, \(untweaked.msPerChange) ms as written")
            exit(0)
        }
        app.run()
    }

    static func jsString(_ text: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), encoding: .utf8)!
    }
}
