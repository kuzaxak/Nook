// Licensed under GPL-3.0. See LICENSE.
//
//  ClickUpTweaks.swift
//  Nook
//

import Foundation
import NookBlocker
import WebKit

// WebKit files a :has() whose argument holds a combinator inside :not() under its scope-breaking
// :has() rules, and then walks the whole document twice for every child inserted or removed
// anywhere (ChildChangeInvalidation::invalidateForChangeOutsideHasScope). ClickUp's chat style has
// two such rules, and its virtual list inserts rows on every frame of a scroll.
@MainActor
public enum ClickUpTweaks {
    private static let marker = "// Nook ClickUp Tweaks"
    private static let world = WKContentWorld.world(name: "NookClickUpTweaks")

    private static let script = """
    \(marker)
    (function () {
      if (!/(^|\\.)clickup\\.com$/.test(location.hostname)) return;
      var costly = ':not(cu-chat-comment-embed *)';
      function sweepRules(rules) {
        for (var i = 0; i < rules.length; i++) {
          var rule = rules[i], text = rule.selectorText;
          if (text && text.indexOf(':has(') !== -1 && text.indexOf(costly) !== -1) rule.selectorText = text.split(costly).join('');
          if (rule.cssRules) sweepRules(rule.cssRules);
        }
      }
      function sweep(sheet) {
        var rules;
        try { rules = sheet && sheet.cssRules; } catch (e) { return; }
        if (rules) sweepRules(rules);
      }
      function added(node) {
        if (node.localName === 'style') sweep(node.sheet);
        else if (node.localName === 'link') node.addEventListener('load', function () { sweep(node.sheet); });
      }
      function watch(head) {
        new MutationObserver(function (records) {
          records.forEach(function (record) { record.addedNodes.forEach(added); });
        }).observe(head, { childList: true });
      }
      if (document.head) {
        watch(document.head);
      } else {
        var waiting = new MutationObserver(function () {
          if (!document.head) return;
          waiting.disconnect();
          watch(document.head);
        });
        waiting.observe(document.documentElement, { childList: true });
      }
      document.addEventListener('DOMContentLoaded', function () {
        Array.prototype.forEach.call(document.styleSheets, sweep);
      });
    })();
    """

    public static func apply(for url: URL, in webView: WKWebView) {
        let source = isClickUp(url.host) ? script : nil
        let ucc = webView.configuration.userContentController
        let all = ucc.userScripts
        let others = all.nookOwned.filter { !$0.source.hasPrefix(marker) }
        let current = all.first { $0.source.hasPrefix(marker) }?.source
        guard current != source else { return }
        ucc.removeAllUserScripts()
        others.forEach { ucc.addUserScript($0) }
        if let source {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        }
    }

    private static func isClickUp(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "clickup.com" || host.hasSuffix(".clickup.com")
    }
}
