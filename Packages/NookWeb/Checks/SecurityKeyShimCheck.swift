// Licensed under GPL-3.0. See LICENSE.
//
//  SecurityKeyShimCheck.swift
//  Nook
//
//  The shipped Resources/vault-passkey.js in JavaScriptCore, answered with SecurityKeyReply's
//  dictionaries: what create() and get() post, the PublicKeyCredential shapes the page gets
//  back (ArrayBuffers, transports, public key, extension results, toJSON), DOMException names,
//  AbortSignal, and the platform switch (false for security keys alone, true with Pawl Vault).
//  Run from the repository root:
//
//    swiftc -parse-as-library \
//      Packages/NookWeb/Sources/NookWeb/SecurityKey/SecurityKeyRequests.swift \
//      Packages/NookWeb/Sources/NookWeb/Vault/{Base64URL,PublicSuffixList,VaultMessages,WebAuthnClientData,WebAuthnError,WebAuthnPolicy}.swift \
//      Packages/NookWeb/Checks/SecurityKeyShimCheck.swift -o /tmp/sk-shim && /tmp/sk-shim
//

import Foundation
import JavaScriptCore

@main
struct SecurityKeyShimCheck {
    static let page = """
    var window = this;
    function DOMException(message, name) { this.message = message; this.name = name; }
    function PublicKeyCredential() {}
    function AuthenticatorAttestationResponse() {}
    function AuthenticatorAssertionResponse() {}
    function CredentialsContainer() {}
    CredentialsContainer.prototype.get = function () { return Promise.resolve('native get'); };
    CredentialsContainer.prototype.create = function () { return Promise.resolve('native create'); };
    var navigator = { credentials: new CredentialsContainer() };
    var posted = [], replies = [], results = {};
    window.webkit = { messageHandlers: { nookPasskey: { postMessage: function (message) {
        posted.push(JSON.parse(JSON.stringify(message)));
        return message.op === 'abort' ? Promise.resolve(null) : new Promise(function (resolve) { replies.push(resolve); });
    } } } };
    function answer(value) { replies.shift()(value); }
    var letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    function btoa(binary) {
        var out = '';
        for (var i = 0; i < binary.length; i += 3) {
            var a = binary.charCodeAt(i), b = binary.charCodeAt(i + 1), c = binary.charCodeAt(i + 2);
            var n = (a << 16) | ((b || 0) << 8) | (c || 0);
            out += letters[n >> 18 & 63] + letters[n >> 12 & 63] + (i + 1 < binary.length ? letters[n >> 6 & 63] : '=') + (i + 2 < binary.length ? letters[n & 63] : '=');
        }
        return out;
    }
    function atob(text) {
        var out = '', bits = 0, value = 0;
        for (var i = 0; i < text.length && text[i] !== '='; i++) {
            value = (value << 6) | letters.indexOf(text[i]); bits += 6;
            if (bits >= 8) { bits -= 8; out += String.fromCharCode((value >> bits) & 255); }
        }
        return out;
    }
    function AbortController() {
        var listeners = [];
        this.signal = { aborted: false, addEventListener: function (n, f) { listeners.push(f); },
                        removeEventListener: function (n, f) { listeners = listeners.filter(function (g) { return g !== f; }); } };
        this.abort = function () { this.signal.aborted = true; listeners.forEach(function (f) { f(); }); };
    }
    function bytes(buffer) { return buffer === null ? null : Array.prototype.slice.call(new Uint8Array(buffer)); }
    function keep(name, promise) {
        promise.then(function (value) { results[name] = { value: value }; }, function (error) { results[name] = { error: error }; });
    }
    """

    static func context(platform: Bool) throws -> JSContext {
        let shim = try String(contentsOfFile: "Packages/NookWeb/Sources/NookWeb/Resources/vault-passkey.js", encoding: .utf8)
        precondition(shim.hasPrefix("// Nook Vault Passkeys") && shim.contains("__NOOK_PLATFORM__"))
        let context = JSContext()!
        context.exceptionHandler = { _, error in preconditionFailure("JS: \(error?.toString() ?? "?")") }
        context.evaluateScript(page)
        context.evaluateScript(shim.replacingOccurrences(of: "__NOOK_PLATFORM__", with: platform ? "true" : "false"))
        return context
    }

    static func json(_ value: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    static func main() throws {
        let js = try context(platform: false)
        func value(_ script: String) -> JSValue { js.evaluateScript(script) }
        func text(_ script: String) -> String { value("JSON.stringify(\(script))").toString() }

        // Security keys alone: no platform authenticator, no conditional mediation.
        js.evaluateScript("keep('uvpaa', PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());"
            + "keep('conditional', PublicKeyCredential.isConditionalMediationAvailable())")
        precondition(text("[results.uvpaa.value, results.conditional.value]") == "[false,false]")
        js.evaluateScript("keep('autofill', navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(16) } }))")
        precondition(text("results.autofill.error.name") == "\"NotSupportedError\"" && value("posted.length").toInt32() == 0)
        js.evaluateScript("keep('password', navigator.credentials.get({ password: true }))")
        precondition(text("results.password.value") == "\"native get\"")

        // create(): what goes to Nook, then the credential built from Nook's reply.
        js.evaluateScript("""
            keep('created', navigator.credentials.create({ publicKey: {
                challenge: new Uint8Array([0, 1, 2]), rp: { id: 'example.com', name: 'Example' },
                user: { id: new Uint8Array([117, 115, 101, 114]), name: 'alice', displayName: 'Alice' },
                pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -8 }],
                excludeCredentials: [{ type: 'public-key', id: new Uint8Array([0xaa, 0xbb, 0xcc]).buffer }],
                authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'required', extra: 1 },
                attestation: 'direct', extensions: { credProps: true }, timeout: 60000 } }));
            """)
        precondition(text("posted[0]") == #"{"op":"create","requestId":1,"challenge":"AAEC","rp":{"id":"example.com","name":"Example"},"user":{"id":"dXNlcg","name":"alice","displayName":"Alice"},"pubKeyCredParams":[-7,-8],"excludeCredentials":["qrvM"],"authenticatorSelection":{"residentKey":"required","userVerification":"required","requireResidentKey":true},"credProps":true,"timeout":60000}"#, text("posted[0]"))
        let made = SecurityKeyCreated(credentialID: Data([0xfb, 0xff, 1]), authenticatorData: Data([5, 6]), attestationObject: Data([7]),
                                      publicKeyAlgorithm: -7, publicKey: Data([8, 9]), residentKey: true)
        js.evaluateScript("answer(\(json(SecurityKeyReply.created(made, clientDataJSON: Data("{}".utf8), credProps: true))))")
        precondition(value("results.created.value instanceof PublicKeyCredential").toBool())
        precondition(text("[results.created.value.id, results.created.value.type, results.created.value.authenticatorAttachment]")
            == #"["-_8B","public-key","cross-platform"]"#)
        precondition(text("bytes(results.created.value.rawId)") == "[251,255,1]")
        let created = "results.created.value.response"
        precondition(value("\(created) instanceof AuthenticatorAttestationResponse").toBool())
        precondition(text("[bytes(\(created).clientDataJSON), bytes(\(created).attestationObject), bytes(\(created).getAuthenticatorData()), bytes(\(created).getPublicKey())]")
            == "[[123,125],[7],[5,6],[8,9]]")
        precondition(text("[\(created).getTransports(), \(created).getPublicKeyAlgorithm()]") == #"[["usb"],-7]"#)
        precondition(text("results.created.value.getClientExtensionResults()") == #"{"credProps":{"rk":true}}"#)
        precondition(text("results.created.value") == #"{"id":"-_8B","rawId":"-_8B","type":"public-key","authenticatorAttachment":"cross-platform","response":{"clientDataJSON":"e30","attestationObject":"Bw","authenticatorData":"BQY","transports":["usb"],"publicKeyAlgorithm":-7,"publicKey":"CAk"},"clientExtensionResults":{"credProps":{"rk":true}}}"#, text("results.created.value"))
        js.evaluateScript("\(created).getTransports().push('nfc'); results.created.value.getClientExtensionResults().credProps.rk = false")
        precondition(text("[\(created).getTransports(), results.created.value.getClientExtensionResults()]") == #"[["usb"],{"credProps":{"rk":true}}]"#)

        // pubKeyCredParams: entries need a type and an integer alg; types other than public-key
        // are skipped, and a list with none left is not supported. Nothing reaches Nook.
        let sentBefore = value("posted.length").toInt32()
        for (name, params, expected) in [
            ("noAlg", "[{ type: 'public-key' }]", "TypeError"), ("textAlg", "[{ type: 'public-key', alg: '-7' }]", "TypeError"),
            ("noType", "[{ alg: -7 }]", "TypeError"), ("notObject", "[-7]", "TypeError"), ("notList", "{ alg: -7 }", "TypeError"),
            ("otherType", "[{ type: 'password', alg: -7 }]", "NotSupportedError"),
        ] {
            js.evaluateScript("keep('\(name)', navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1) }, pubKeyCredParams: \(params) } }))")
            precondition(text("results.\(name).error.name") == "\"\(expected)\"", "\(name): \(text("results.\(name).error"))")
        }
        precondition(value("posted.length").toInt32() == sentBefore)
        js.evaluateScript("keep('mixed', navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1) }, pubKeyCredParams: [{ type: 'password', alg: -8 }, { type: 'public-key', alg: -7 }] } }))")
        precondition(text("posted[posted.length - 1].pubKeyCredParams") == "[-7]")
        js.evaluateScript("answer({ error: 'NotAllowedError' })")

        // A key whose algorithm Nook cannot express as SPKI: getPublicKey() is null.
        js.evaluateScript("keep('rsa', navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1) } } }))")
        let rsa = SecurityKeyCreated(credentialID: Data([1]), authenticatorData: Data([2]), attestationObject: Data([3]),
                                     publicKeyAlgorithm: -257, publicKey: nil, residentKey: false)
        js.evaluateScript("answer(\(json(SecurityKeyReply.created(rsa, clientDataJSON: Data("{}".utf8), credProps: false))))")
        precondition(text("[results.rsa.value.response.getPublicKey(), results.rsa.value.getClientExtensionResults(), 'publicKey' in results.rsa.value.toJSON().response]")
            == "[null,{},false]")

        // get(): the payload, then an assertion.
        js.evaluateScript("""
            keep('got', navigator.credentials.get({ publicKey: { challenge: new Uint8Array([0, 1, 2]), rpId: 'example.com',
                allowCredentials: [{ type: 'public-key', id: new Uint8Array([1]) }], userVerification: 'discouraged', timeout: 30000 } }));
            """)
        precondition(text("posted[posted.length - 1]") == #"{"op":"get","requestId":4,"challenge":"AAEC","rpId":"example.com","allowCredentials":["AQ"],"userVerification":"discouraged","mediation":"optional","timeout":30000}"#, text("posted[posted.length - 1]"))
        let signed = SecurityKeyAsserted(credentialID: Data([1]), authenticatorData: Data([2, 3]), signature: Data([4]), userHandle: Data([5]))
        js.evaluateScript("answer(\(json(SecurityKeyReply.asserted(signed, clientDataJSON: Data("{}".utf8)))))")
        let got = "results.got.value"
        precondition(value("\(got) instanceof PublicKeyCredential && \(got).response instanceof AuthenticatorAssertionResponse").toBool())
        precondition(text("[\(got).id, \(got).authenticatorAttachment, bytes(\(got).response.authenticatorData), bytes(\(got).response.signature), bytes(\(got).response.userHandle)]")
            == #"["AQ","cross-platform",[2,3],[4],[5]]"#)
        precondition(text("\(got).getClientExtensionResults()") == "{}")
        js.evaluateScript("keep('anonymous', navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } }))")
        let anonymous = SecurityKeyAsserted(credentialID: Data([1]), authenticatorData: Data([2]), signature: Data([3]), userHandle: nil)
        js.evaluateScript("answer(\(json(SecurityKeyReply.asserted(anonymous, clientDataJSON: Data("{}".utf8)))))")
        precondition(text("[results.anonymous.value.response.userHandle, results.anonymous.value.toJSON().response.userHandle]") == "[null,null]")

        // Errors are DOMExceptions with Nook's name.
        for name in ["NotAllowedError", "InvalidStateError", "SecurityError", "NotSupportedError"] {
            js.evaluateScript("keep('\(name)', navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } })); answer({ error: '\(name)' })")
            precondition(text("results.\(name).error.name") == "\"\(name)\"" && value("results.\(name).error instanceof DOMException").toBool())
        }
        js.evaluateScript("keep('nothing', navigator.credentials.get({ publicKey: { challenge: new Uint8Array(1) } })); answer(null)")
        precondition(text("results.nothing.error.name") == "\"NotAllowedError\"")

        // AbortSignal: an aborted request tells Nook and rejects; one aborted before is never sent.
        js.evaluateScript("""
            var controller = new AbortController(), before = posted.length;
            keep('aborted', navigator.credentials.get({ signal: controller.signal, publicKey: { challenge: new Uint8Array(1) } }));
            controller.abort();
            """)
        precondition(text("results.aborted.error.name") == "\"AbortError\"")
        precondition(text("posted.slice(before).map(function (m) { return m.op; })") == #"["get","abort"]"#)
        precondition(value("posted[posted.length - 1].requestId === posted[posted.length - 2].requestId").toBool())
        js.evaluateScript("answer({ id: 'AQ' })")
        precondition(text("results.aborted.error.name") == "\"AbortError\"")
        js.evaluateScript("""
            var early = new AbortController(); early.abort(); before = posted.length;
            keep('early', navigator.credentials.create({ signal: early.signal, publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1) } } }));
            """)
        precondition(text("results.early.error.name") == "\"AbortError\"" && value("posted.length === before").toBool())

        // Pawl Vault connected: a platform authenticator and conditional mediation; vault replies keep their shape.
        let vault = try context(platform: true)
        vault.evaluateScript("keep('uvpaa', PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());"
            + "keep('conditional', PublicKeyCredential.isConditionalMediationAvailable())")
        precondition(vault.evaluateScript("JSON.stringify([results.uvpaa.value, results.conditional.value])").toString() == "[true,true]")
        vault.evaluateScript("keep('autofill', navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array(1) } }))")
        precondition(vault.evaluateScript("posted[0].mediation").toString() == "conditional")
        vault.evaluateScript("answer({ error: 'AbortError' })")
        vault.evaluateScript("""
            keep('made', navigator.credentials.create({ publicKey: { challenge: new Uint8Array(1), rp: {}, user: { id: new Uint8Array(1) } } }));
            answer({ id: 'AQ', clientDataJSON: 'e30', attestationObject: 'Bw', authenticatorData: 'BQY', publicKeyAlgorithm: -7 });
            """)
        precondition(vault.evaluateScript("JSON.stringify([results.made.value.authenticatorAttachment, results.made.value.response.getTransports(), Object.keys(results.made.value.response).indexOf('getPublicKey'), results.made.value.getClientExtensionResults()])").toString()
            == #"["platform",["internal"],-1,{}]"#)

        print("SecurityKeyShimCheck passed")
    }
}
