// Licensed under GPL-3.0. See LICENSE.
//
//  VaultCodeFieldCheck.swift
//  Nook
//
//  One-time-code fields (bridge Amendment 4): which inputs the form script offers codes for, how
//  a picked code lands in a single field or one digit per box of a split field, and that the
//  form is never submitted. Runs the shipped Resources/vault-autofill.js in JavaScriptCore
//  against a minimal DOM. Run from the repository root:
//
//    swiftc -parse-as-library Packages/NookWeb/Checks/VaultCodeFieldCheck.swift \
//           -o /tmp/vault-code-field && /tmp/vault-code-field
//

import Foundation
import JavaScriptCore

@main
struct VaultCodeFieldCheck {
    static let dom = """
    var window = this;
    window.top = window;
    var location = { protocol: 'https:', origin: 'https://example.com' };
    var Node = { DOCUMENT_POSITION_FOLLOWING: 4 };
    var posted = [];
    var submitted = 0;
    window.webkit = { messageHandlers: { nookAutofill: { postMessage: function (m) { posted.push(m); } } } };
    function Event(type) { this.type = type; }
    function Form() { this.inputs = []; }
    Form.prototype.querySelectorAll = function (selector) {
      return selector === 'input' ? this.inputs : this.inputs.filter(function (i) { return i.type === 'password'; });
    };
    Form.prototype.submit = Form.prototype.requestSubmit = function () { submitted++; };
    function Element() {}
    Element.prototype.getAttribute = function (n) { return this.attrs[n] === undefined ? null : this.attrs[n]; };
    Element.prototype.getClientRects = function () { return this.hidden ? [] : [1]; };
    Element.prototype.getBoundingClientRect = function () { return { left: 10, top: 20, width: 100, height: 30 }; };
    Element.prototype.closest = function () { return this.form; };
    Element.prototype.getRootNode = function () { return document; };
    Element.prototype.dispatchEvent = function (e) { this.events.push(e.type); };
    function HTMLInputElement(form, type, attrs, labels) {
      this.form = form; this.type = type; this.attrs = attrs || {};
      this.name = this.attrs.name || ''; this.id = this.attrs.id || '';
      this.maxLength = this.attrs.maxlength === undefined ? -1 : Number(this.attrs.maxlength);
      this.labels = (labels || []).map(function (text) { return { textContent: text }; });
      this.disabled = false; this.readOnly = false; this.hidden = false; this.isConnected = true; this.events = [];
      form.inputs.push(this);
    }
    HTMLInputElement.prototype = Object.create(Element.prototype);
    Object.defineProperty(HTMLInputElement.prototype, 'value', {
      get: function () { return this._value || ''; }, set: function (v) { this._value = v; }, configurable: true });
    function HTMLButtonElement() { this.type = 'button'; this.attrs = {}; }
    HTMLButtonElement.prototype = Object.create(Element.prototype);
    var document = { listeners: {}, querySelectorAll: function () { return []; },
      addEventListener: function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); } };
    function dispatch(type, target, trusted, key) {
      var event = { type: type, isTrusted: trusted, key: key, target: target, composedPath: function () { return [target]; } };
      (document.listeners[type] || []).forEach(function (f) { f(event); });
    }
    function field(type, attrs, labels) { return new HTMLInputElement(new Form(), type, attrs, labels); }
    function hidden(input) { input.hidden = true; return input; }
    function boxes(form, count, type) {
      var made = [];
      for (var i = 0; i < count; i++) made.push(new HTMLInputElement(form, type || 'text', { maxlength: '1' }));
      return made;
    }
    function openedKind(input) {
      posted.length = 0;
      dispatch('mousedown', input, true);
      return posted.length ? posted[0].kind : null;
    }
    """

    static func main() throws {
        let source = try String(contentsOfFile: "Packages/NookWeb/Sources/NookWeb/Resources/vault-autofill.js", encoding: .utf8)
        let context = JSContext()!
        context.exceptionHandler = { _, error in preconditionFailure("JS: \(error?.toString() ?? "?")") }
        context.evaluateScript(dom)
        context.evaluateScript(source)
        @discardableResult func js(_ script: String) -> JSValue { context.evaluateScript(script) }
        func kind(_ make: String) -> String? {
            let value = js("openedKind(\(make))")
            return value.isNull ? nil : value.toString()
        }

        // autocomplete="one-time-code", or a hinted text/tel/number input with maxlength 4–8 or a numeric keypad.
        let codeFields = [
            "field('text', { autocomplete: 'one-time-code' })",
            "field('email', { autocomplete: 'section-login one-time-code' })",
            "field('tel', { name: 'otp', maxlength: '6' })",
            "field('number', { id: 'totp-input', inputmode: 'numeric' })",
            "field('text', { placeholder: 'Verification code', maxlength: '6' })",
            "field('text', { 'aria-label': 'Security Code', maxlength: '8' })",
            "field('text', { inputmode: 'numeric' }, ['Enter your 2FA code'])",
            "field('text', { name: 'mfa', maxlength: '4' })",
            "field('text', { maxlength: '6' }, ['One-time password'])",
            "field('text', { placeholder: 'Authentication code', inputmode: 'NUMERIC' })",
            "field('text', { name: 'auth_code', maxlength: '6' })",
            "field('tel', { maxlength: '6' }, ['2-step verification'])",
        ]
        for make in codeFields { precondition(kind(make) == "code", make) }

        // A password input keeps today's picker; a hint alone, the wrong length or type, or no hint is no code field.
        let notCode: [(String, String?)] = [
            ("field('password', { autocomplete: 'one-time-code' })", "password"),
            ("field('password', { name: 'otp', maxlength: '6' })", "password"),
            ("field('text', { name: 'otp' })", nil),
            ("field('text', { name: 'otp', maxlength: '3' })", nil),
            ("field('text', { name: 'otp', maxlength: '9' })", nil),
            ("field('email', { name: 'otp', maxlength: '6' })", nil),
            ("field('text', { name: 'code', maxlength: '6' })", nil),
            ("field('text', { name: 'username', maxlength: '6' })", "username"),
            ("hidden(field('text', { autocomplete: 'one-time-code' }))", nil),
        ]
        for (make, expected) in notCode { precondition(kind(make) == expected, make) }

        // 4–8 adjacent single-character inputs in one form are one split field, from any of its boxes.
        for count in [4, 6, 8] {
            precondition(js("boxes(new Form(), \(count)).map(openedKind).every(function (k) { return k === 'code'; })").toBool(),
                         "\(count) boxes")
        }
        for count in [3, 9] {
            precondition(!js("boxes(new Form(), \(count)).map(openedKind).some(function (k) { return k === 'code'; })").toBool(),
                         "\(count) boxes")
        }
        precondition(!js("boxes(new Form(), 3).concat(boxes(new Form(), 3)).map(openedKind).some(function (k) { return k === 'code'; })").toBool(),
                     "boxes in two forms")
        precondition(!js("""
            (function () {
              var form = new Form(), first = boxes(form, 3);
              new HTMLInputElement(form, 'text', { name: 'note' });
              return first.concat(boxes(form, 3)).map(openedKind).some(function (k) { return k === 'code'; });
            })()
            """).toBool(), "boxes with another input between them")
        precondition(js("boxes(new Form(), 6, 'password').map(openedKind).every(function (k) { return k === 'password'; })").toBool(),
                     "password boxes")

        // Only a trusted mousedown or ArrowDown offers codes; focus and page-made events do not.
        js("var single = field('tel', { name: 'otp', maxlength: '6' }); posted.length = 0")
        js("dispatch('focusin', single, true); dispatch('mousedown', single, false); dispatch('keydown', single, false, 'ArrowDown')")
        precondition(!js("posted.some(function (m) { return m.type === 'open'; })").toBool(), "a code field opened without a trusted gesture")
        js("posted.length = 0; dispatch('keydown', single, true, 'ArrowDown')")
        precondition(js("posted.length === 1 && posted[0].type === 'open' && posted[0].kind === 'code'").toBool())

        // The picked code fills the field the picker opened for, with input and change events, on its origin only.
        precondition(js("__nookVaultFillCode('https://evil.example', '012345')").toBool() == false)
        precondition(js("single.value").toString() == "" && js("single.events.length").toInt32() == 0)
        precondition(js("__nookVaultFillCode('https://example.com', '012345')").toBool())
        precondition(js("single.value").toString() == "012345")
        precondition(js("single.events.join()").toString() == "input,change")

        // A split field gets one digit per box, whichever box was clicked.
        js("var row = boxes(new Form(), 6); openedKind(row[2])")
        precondition(js("__nookVaultFillCode('https://example.com', '123456')").toBool())
        precondition(js("row.map(function (b) { return b.value; }).join('|')").toString() == "1|2|3|4|5|6")
        precondition(js("row.every(function (b) { return b.events.join() === 'input,change'; })").toBool())

        // A code never lands in a field that is not a code field.
        js("var secret = field('password', {}); openedKind(secret)")
        precondition(js("__nookVaultFillCode('https://example.com', '999999')").toBool() == false)
        precondition(js("secret.value").toString() == "")

        precondition(js("submitted").toInt32() == 0, "a fill submitted the form")
        precondition(js("posted.every(function (m) { return m.type !== 'submit'; })").toBool())

        print("VaultCodeFieldCheck passed")
    }
}
