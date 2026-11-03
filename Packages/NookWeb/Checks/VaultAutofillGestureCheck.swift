// Licensed under GPL-3.0. See LICENSE.
//
//  VaultAutofillGestureCheck.swift
//  Nook
//
//  The form script asks for Nook's account picker only after a real user gesture in a login
//  field: a trusted mousedown, or a trusted ArrowDown. Focus never opens it, and neither do events
//  the page synthesizes. Runs the shipped Resources/vault-autofill.js in JavaScriptCore against a
//  minimal DOM. Run from the repository root:
//
//    swiftc -parse-as-library Packages/NookWeb/Checks/VaultAutofillGestureCheck.swift \
//           -o /tmp/vault-gesture && /tmp/vault-gesture
//

import Foundation
import JavaScriptCore

@main
struct VaultAutofillGestureCheck {
    static let dom = """
    var window = this;
    window.top = window;
    var location = { protocol: 'https:', origin: 'https://example.com' };
    var Node = { DOCUMENT_POSITION_FOLLOWING: 4 };
    var posted = [];
    window.webkit = { messageHandlers: { nookAutofill: { postMessage: function (m) { posted.push(m); } } } };
    var all = [];
    function Element() {}
    Element.prototype.getAttribute = function (n) { return this.attrs[n] === undefined ? null : this.attrs[n]; };
    Element.prototype.getClientRects = function () { return [1]; };
    Element.prototype.getBoundingClientRect = function () { return { left: 10, top: 20, width: 100, height: 30 }; };
    Element.prototype.closest = function () { return this.form || null; };
    Element.prototype.getRootNode = function () { return document; };
    Element.prototype.compareDocumentPosition = function (o) { return all.indexOf(o) > all.indexOf(this) ? 4 : 2; };
    function HTMLInputElement(type, attrs, form) {
      this.type = type; this.attrs = attrs || {}; this.form = form; this.name = this.attrs.name || '';
      this.id = ''; this.disabled = false; this.readOnly = false; all.push(this);
    }
    HTMLInputElement.prototype = Object.create(Element.prototype);
    Object.defineProperty(HTMLInputElement.prototype, 'value', {
      get: function () { return this._value || ''; }, set: function (v) { this._value = v; }, configurable: true });
    function HTMLButtonElement() { this.type = 'button'; this.attrs = {}; }
    HTMLButtonElement.prototype = Object.create(Element.prototype);
    function query(selector) {
      return all.filter(function (i) { return selector === 'input' || i.type === 'password'; });
    }
    var form = { querySelectorAll: query };
    var document = { listeners: {}, querySelectorAll: query,
      addEventListener: function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); } };
    function dispatch(type, target, trusted, key) {
      var event = { type: type, isTrusted: trusted, key: key, target: target, composedPath: function () { return [target]; } };
      (document.listeners[type] || []).forEach(function (f) { f(event); });
    }
    var user = new HTMLInputElement('email', { autocomplete: 'username webauthn' }, form);
    var password = new HTMLInputElement('password', {}, form);
    var button = new HTMLButtonElement();
    function opened() { return posted.filter(function (m) { return m.type === 'open'; }); }
    """

    static func main() throws {
        let source = try String(contentsOfFile: "Packages/NookWeb/Sources/NookWeb/Resources/vault-autofill.js", encoding: .utf8)
        let context = JSContext()!
        context.exceptionHandler = { _, error in preconditionFailure("JS: \(error?.toString() ?? "?")") }
        context.evaluateScript(dom)
        context.evaluateScript(source)
        func opened() -> Int { Int(context.evaluateScript("opened().length").toInt32()) }
        func run(_ script: String) { context.evaluateScript(script) }

        // Focus alone, trusted or not, never opens the picker.
        run("dispatch('focusin', password, true); dispatch('focus', password, true); dispatch('focusin', user, true)")
        precondition(opened() == 0, "focus opened the picker")

        // Events the page synthesizes are not trusted.
        run("dispatch('mousedown', password, false); dispatch('keydown', user, false, 'ArrowDown')")
        precondition(opened() == 0, "an untrusted event opened the picker")

        // A trusted mousedown in a login field opens it, with the field's kind and rect.
        run("dispatch('mousedown', password, true)")
        precondition(opened() == 1)
        precondition(context.evaluateScript("opened()[0].kind").toString() == "password")
        precondition(context.evaluateScript("opened()[0].rect.width").toInt32() == 100)
        precondition(context.evaluateScript("opened()[0].webauthn").toBool() == false)

        // A trusted ArrowDown opens it; typing does not.
        run("dispatch('keydown', user, true, 'a'); dispatch('keydown', user, true, 'Enter')")
        precondition(opened() == 1, "typing opened the picker")
        run("dispatch('keydown', user, true, 'ArrowDown')")
        precondition(opened() == 2)
        precondition(context.evaluateScript("opened()[1].kind").toString() == "username")
        precondition(context.evaluateScript("opened()[1].webauthn").toBool() == true, "conditional passkeys need the webauthn flag")

        // A gesture outside a login field opens nothing.
        run("dispatch('mousedown', button, true)")
        precondition(opened() == 2)

        print("VaultAutofillGestureCheck passed")
    }
}
