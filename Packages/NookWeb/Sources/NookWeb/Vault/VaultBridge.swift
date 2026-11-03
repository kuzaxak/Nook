// Licensed under GPL-3.0. See LICENSE.
//
//  VaultBridge.swift
//  Nook
//
//  One web view's link to Pawl Vault. Passwords and one-time codes: the form script and its
//  handler live in the isolated NookAutofill world; Nook shows the accounts for the frame's
//  origin (for a code field, those with a code) and fills through that world after the user
//  picks one. Passkeys: while the vault is connected, a page-world shim replaces the
//  suppression script and posts to the reply handler `nookPasskey`. The origin always comes
//  from WebKit's frame info, and nothing is signed or filled without Nook's own picker or
//  confirmation first.
//

#if os(macOS)
import AppKit
import WebKit

@MainActor
final class VaultBridge: NSObject, WKScriptMessageHandler, WKScriptMessageHandlerWithReply {
    static let autofillWorld = WKContentWorld.world(name: "NookAutofill")
    static let autofillHandlerName = "nookAutofill"
    static let passkeyHandlerName = "nookPasskey"

    private static let autofillMarker = "// Nook Vault Autofill"
    private static let passkeyMarker = "// Nook Vault Passkeys"
    private static let suppressionMarker = "// Nook Passkey Suppression"
    private static let autofillSource = resource("vault-autofill")
    private static let passkeySource = resource("vault-passkey")
    private static let live = NSHashTable<VaultBridge>.weakObjects()

    private static func resource(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Resources"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return source
    }

    private weak var service: VaultService?
    private weak var session: PageSession?
    private weak var webView: WKWebView?
    private weak var controller: WKUserContentController?
    private var passkeyHandlerInstalled = false
    /// Passkey requests not yet answered, by the shim's request id.
    private var inFlight: [Int: PasskeyReply] = [:]
    /// `mediation: "conditional"` requests, offered when a webauthn field takes focus.
    private var conditionalGets: [Int: GetRequest] = [:]
    /// The request whose picker is open.
    private var modalGetID: Int?
    /// Token of the picker this bridge has open; a stale picker's completion never clears a newer one.
    private var openPicker: Int?
    private var pickerCount = 0
    /// Bumped by every open request and close, so a slow vault lookup cannot open a picker late.
    private var focusGeneration = 0
    /// The main frame's origin as of its last commit; a subframe must match it.
    private var committedOrigin: String?

    private init(session: PageSession, service: VaultService, webView: WKWebView) {
        self.session = session
        self.service = service
        self.webView = webView
        self.controller = webView.configuration.userContentController
    }

    // MARK: - Install

    static func install(on webView: WKWebView, session: PageSession, service: VaultService) {
        let controller = webView.configuration.userContentController
        uninstall(from: controller)
        let bridge = VaultBridge(session: session, service: service, webView: webView)
        controller.add(bridge, contentWorld: autofillWorld, name: autofillHandlerName)
        live.add(bridge)
        bridge.syncScripts()
    }

    static func uninstall(from controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: autofillHandlerName, contentWorld: autofillWorld)
        controller.removeScriptMessageHandler(forName: passkeyHandlerName, contentWorld: .page)
        for bridge in live.allObjects where bridge.controller === controller {
            bridge.passkeyHandlerInstalled = false
            bridge.documentChanged()
            live.remove(bridge)
        }
    }

    static func syncAll() {
        live.allObjects.forEach { $0.syncScripts() }
    }

    static func bridge(for webView: WKWebView) -> VaultBridge? {
        live.allObjects.first { $0.webView === webView }
    }

    /// Form script while the setting is on; passkey shim and handler while the vault is
    /// connected, the suppression script otherwise. Scripts apply from the next document.
    private func syncScripts() {
        guard let controller, let service else { return }
        let autofill = service.isEnabled
        let passkeys = service.isConnected
        // Read the bridged array fully before removeAllUserScripts() (Release-only trap).
        let all = Array(controller.userScripts)
        func has(_ marker: String) -> Bool { all.contains { $0.source.hasPrefix(marker) } }
        if has(Self.autofillMarker) != autofill || has(Self.passkeyMarker) != passkeys || has(Self.suppressionMarker) == passkeys {
            let ours = [Self.autofillMarker, Self.passkeyMarker, Self.suppressionMarker]
            let keep = all.nookOwned.filter { script in !ours.contains { script.source.hasPrefix($0) } }
            controller.removeAllUserScripts()
            keep.forEach(controller.addUserScript)
            controller.addUserScript(passkeys
                ? WKUserScript(source: Self.passkeySource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
                : BrowserConfiguration.passkeySuppressionScript)
            if autofill {
                controller.addUserScript(WKUserScript(
                    source: Self.autofillSource, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.autofillWorld))
            }
        }
        if passkeys != passkeyHandlerInstalled {
            controller.removeScriptMessageHandler(forName: Self.passkeyHandlerName, contentWorld: .page)
            if passkeys { controller.addScriptMessageHandler(self, contentWorld: .page, name: Self.passkeyHandlerName) }
            passkeyHandlerInstalled = passkeys
        }
        if !passkeys { endPasskeyRequests(.notAllowed) }
    }

    /// A new main-frame document committed with `origin`.
    func pageCommitted(origin: String?) {
        committedOrigin = origin
        documentChanged()
    }

    /// The page's document went away: its requests end and its pickers close.
    func documentChanged() {
        endPasskeyRequests(.abort)
        closePicker()
    }

    private func endPasskeyRequests(_ error: WebAuthnError) {
        inFlight.values.forEach { $0.fail(error) }
        inFlight = [:]
        conditionalGets = [:]
        modalGetID = nil
    }

    private func closePicker() {
        focusGeneration += 1
        guard openPicker != nil, let webView else { return }
        openPicker = nil
        service?.presenter?.dismissPicker(in: webView)
    }

    private func pickerOpened() -> Int {
        pickerCount += 1
        openPicker = pickerCount
        return pickerCount
    }

    /// Whether `token` was the open picker; it no longer is.
    private func pickerClosed(_ token: Int) -> Bool {
        guard openPicker == token else { return false }
        openPicker = nil
        return true
    }

    private var profile: String? { session?.profile?.id.uuidString }

    /// `scheme://host[:port]` of a frame Nook may serve: HTTPS, or HTTP on localhost.
    private static func allowedOrigin(of frame: WKFrameInfo) -> String? {
        let origin = frame.securityOrigin
        guard WebAuthnPolicy.isAllowedOrigin(scheme: origin.protocol, host: origin.host) else { return nil }
        return WebAuthnPolicy.origin(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    // MARK: - Passwords (NookAutofill world)

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.autofillHandlerName, message.world == Self.autofillWorld,
              service?.isEnabled == true, let webView = message.webView, webView === self.webView,
              let body = message.body as? [String: Any], let type = body["type"] as? String,
              let origin = Self.allowedOrigin(of: message.frameInfo)
        else { return }
        switch type {
        case "open":
            showAccounts(frame: message.frameInfo, origin: origin, rect: body["rect"] as? [String: Any],
                         webauthn: body["webauthn"] as? Bool ?? false, code: body["kind"] as? String == "code", in: webView)
        case "blur":
            closePicker()
        case "submit":
            guard let username = body["username"] as? String, let password = body["password"] as? String,
                  !username.isEmpty, !password.isEmpty
            else { return }
            offerSave(username: username, password: password, origin: origin,
                      host: message.frameInfo.securityOrigin.host, in: webView)
        default:
            break
        }
    }

    private func showAccounts(frame: WKFrameInfo, origin: String, rect: [String: Any]?, webauthn: Bool, code: Bool,
                              in webView: WKWebView) {
        focusGeneration += 1
        let generation = focusGeneration
        let anchor = Self.anchor(for: rect, in: webView)
        let conditional = webauthn && !code ? conditionalGets.values.filter { $0.origin == origin }.max { $0.id < $1.id } : nil
        let profile = profile
        Task {
            guard let service else { return }
            let logins = (try? await service.send(VaultLogins(origin: origin, profile: profile)))?.logins ?? []
            var passkeys: [VaultPasskey] = []
            if let conditional {
                let call = VaultPasskeys(rpId: conditional.rpId, allowCredentials: conditional.allowCredentials, profile: profile)
                passkeys = (try? await service.send(call))?.passkeys ?? []
            }
            let items = code
                ? logins.filter(\.hasCode).map(VaultPickerItem.init(code:))
                : passkeys.map(VaultPickerItem.init) + logins.map(VaultPickerItem.init(_:))
            guard generation == focusGeneration, !items.isEmpty, let presenter = service.presenter else { return }
            let token = pickerOpened()
            presenter.presentPicker(host: frame.securityOrigin.host, items: items, anchor: anchor, in: webView) { [weak self] item in
                guard let self, self.pickerClosed(token) else { return }
                self.picked(item, frame: frame, origin: origin, conditionalID: conditional?.id, in: webView)
            }
        }
    }

    private func picked(_ item: VaultPickerItem?, frame: WKFrameInfo, origin: String, conditionalID: Int?, in webView: WKWebView) {
        guard let item, let service else { return }
        switch item.kind {
        case .login(let id):
            let call = VaultPassword(id: id, origin: origin, profile: profile)
            Task {
                guard let reply = try? await service.send(call) else { return }
                // The script checks the frame still shows `origin` before it fills.
                _ = try? await webView.callAsyncJavaScript(
                    "return window.__nookVaultFill && window.__nookVaultFill(origin, username, password);",
                    arguments: ["origin": origin, "username": reply.username, "password": reply.password],
                    in: frame, contentWorld: Self.autofillWorld)
            }
        case .code(let id):
            let call = VaultCode(id: id, origin: origin, profile: profile)
            Task {
                guard let reply = try? await service.send(call) else { return }
                _ = try? await webView.callAsyncJavaScript(
                    "return window.__nookVaultFillCode && window.__nookVaultFillCode(origin, code);",
                    arguments: ["origin": origin, "code": reply.code],
                    in: frame, contentWorld: Self.autofillWorld)
            }
        case .passkey(let credentialId):
            guard let conditionalID, let request = conditionalGets.removeValue(forKey: conditionalID) else { return }
            Task { await finishGet(request, credentialId: credentialId) }
        }
    }

    private func offerSave(username: String, password: String, origin: String, host: String, in webView: WKWebView) {
        guard let service else { return }
        let profile = profile
        Task {
            guard let logins = try? await service.send(VaultLogins(origin: origin, profile: profile)).logins,
                  !logins.contains(where: { $0.username == username }),
                  let presenter = service.presenter
            else { return }
            presenter.offerSave(host: host, username: VaultPrompt.displayText(username), in: webView) { save in
                guard save else { return }
                Task { _ = try? await service.send(VaultSave(origin: origin, username: username, password: password, profile: profile)) }
            }
        }
    }

    /// The field's rect in the web view, from CSS pixels in the top frame's viewport. A frame
    /// inside a cross-origin parent cannot know where it is, so the click that focused it stands in.
    private static func anchor(for rect: [String: Any]?, in webView: WKWebView) -> CGRect {
        let bounds = webView.bounds
        if let rect, let x = rect["x"] as? Double, let y = rect["y"] as? Double,
           let width = rect["width"] as? Double, let height = rect["height"] as? Double {
            let zoom = webView.pageZoom
            var frame = CGRect(x: x * zoom, y: y * zoom, width: max(width * zoom, 1), height: max(height * zoom, 1))
            if !webView.isFlipped { frame.origin.y = bounds.height - frame.maxY }
            let visible = frame.intersection(bounds)
            return visible.isNull || visible.isEmpty ? topAnchor(in: webView) : visible
        }
        guard let window = webView.window else { return topAnchor(in: webView) }
        let point = webView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? CGRect(origin: point, size: CGSize(width: 1, height: 1)) : topAnchor(in: webView)
    }

    private static func topAnchor(in webView: WKWebView) -> CGRect {
        let bounds = webView.bounds
        return CGRect(x: bounds.midX, y: webView.isFlipped ? bounds.minY : bounds.maxY - 1, width: 1, height: 1)
    }

    // MARK: - Passkeys (page world, reply handler)

    private struct PageContext {
        let origin: String
        let host: String
        let profile: String?
    }

    private struct GetRequest {
        let id: Int
        let rpId: String
        let allowCredentials: [String]
        let userVerification: String
        let clientDataJSON: Data
        let origin: String
        let profile: String?
        let reply: PasskeyReply
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let reply = PasskeyReply(replyHandler)
        guard message.name == Self.passkeyHandlerName, message.world == .page, message.webView === webView,
              let body = message.body as? [String: Any], let op = body["op"] as? String,
              let requestID = body["requestId"] as? Int
        else { return reply.fail(.notAllowed) }

        inFlight = inFlight.filter { $0.value.isPending }
        switch op {
        case "abort":
            inFlight.removeValue(forKey: requestID)?.fail(.abort)
            conditionalGets.removeValue(forKey: requestID)
            if modalGetID == requestID { closePicker() }
            reply.finish()
        case "get", "create":
            let context: PageContext
            switch self.context(for: message) {
            case .success(let value): context = value
            case .failure(let error): return reply.fail(error)
            }
            inFlight[requestID] = reply
            Task {
                if op == "get" {
                    await get(body, id: requestID, context: context, reply: reply)
                } else {
                    await create(body, context: context, reply: reply)
                }
            }
        default:
            reply.fail(.notAllowed)
        }
    }

    /// Origin from WebKit; the main frame or a frame with its origin; HTTPS or local HTTP.
    private func context(for message: WKScriptMessage) -> Result<PageContext, WebAuthnError> {
        guard service?.isEnabled == true, let webView = message.webView else { return .failure(.notAllowed) }
        let security = message.frameInfo.securityOrigin
        guard let origin = WebAuthnPolicy.origin(scheme: security.protocol, host: security.host, port: security.port)
        else { return .failure(.security) }
        guard WebAuthnPolicy.isAllowedFrame(isMainFrame: message.frameInfo.isMainFrame, frameOrigin: origin,
                                            mainFrameOrigin: committedOrigin)
        else { return .failure(.notAllowed) }
        guard WebAuthnPolicy.isAllowedOrigin(scheme: security.protocol, host: security.host) else { return .failure(.security) }
        return .success(PageContext(origin: origin, host: security.host.lowercased(), profile: profile))
    }

    private static func validCredentialIDs(_ value: Any?) -> [String]? {
        let ids = value as? [String] ?? []
        return ids.allSatisfy({ Base64URL.decode($0) != nil }) ? ids : nil
    }

    private func get(_ body: [String: Any], id: Int, context: PageContext, reply: PasskeyReply) async {
        guard let service, let challenge = (body["challenge"] as? String).flatMap(Base64URL.decode),
              let allow = Self.validCredentialIDs(body["allowCredentials"])
        else { return reply.fail(.notAllowed) }
        let rpId = ((body["rpId"] as? String) ?? context.host).lowercased()
        guard WebAuthnPolicy.isValidRPID(rpId, forHost: context.host, suffixes: VaultService.suffixes) else { return reply.fail(.security) }
        guard await service.refresh(profile: context.profile) == .connected else { return reply.fail(.notAllowed) }

        let requested = body["userVerification"] as? String ?? ""
        let request = GetRequest(
            id: id, rpId: rpId, allowCredentials: allow,
            userVerification: ["required", "preferred", "discouraged"].contains(requested) ? requested : "preferred",
            clientDataJSON: WebAuthnClientData.json(.get, challenge: challenge, origin: context.origin),
            origin: context.origin, profile: context.profile, reply: reply)
        if body["mediation"] as? String == "conditional" {
            if reply.isPending { conditionalGets[id] = request }
            return
        }

        let passkeys: [VaultPasskey]
        do {
            passkeys = try await service.send(VaultPasskeys(rpId: rpId, allowCredentials: allow, profile: context.profile)).passkeys
        } catch {
            return reply.fail(WebAuthnError(error as? VaultClientError ?? .malformedResponse, creating: false))
        }
        guard reply.isPending else { return }
        guard let presenter = service.presenter, let webView else { return reply.fail(.notAllowed) }
        // The picker is the user's consent in Nook, even for one passkey; the vault adds Touch ID.
        closePicker()
        modalGetID = id
        let token = pickerOpened()
        presenter.presentPicker(host: context.host, items: passkeys.map(VaultPickerItem.init), anchor: Self.topAnchor(in: webView),
                                in: webView) { [weak self] item in
            _ = self?.pickerClosed(token)
            if self?.modalGetID == id { self?.modalGetID = nil }
            guard let self, case .passkey(let credentialId)? = item?.kind else { return reply.fail(.notAllowed) }
            Task { await self.finishGet(request, credentialId: credentialId) }
        }
    }

    private func finishGet(_ request: GetRequest, credentialId: String) async {
        guard request.reply.isPending, let service else { return }
        let call = VaultAssert(
            rpId: request.rpId, credentialId: credentialId,
            clientDataHash: Base64URL.encode(WebAuthnClientData.hash(request.clientDataJSON)),
            userVerification: request.userVerification, origin: request.origin, profile: request.profile)
        do {
            let result = try await service.send(call)
            request.reply.succeed([
                "id": result.credentialId,
                "clientDataJSON": Base64URL.encode(request.clientDataJSON),
                "authenticatorData": result.authenticatorData,
                "signature": result.signature,
                "userHandle": result.userHandle.map { $0 as Any } ?? NSNull(),
            ])
        } catch {
            request.reply.fail(WebAuthnError(error as? VaultClientError ?? .malformedResponse, creating: false))
        }
    }

    private func create(_ body: [String: Any], context: PageContext, reply: PasskeyReply) async {
        guard let service, let challenge = (body["challenge"] as? String).flatMap(Base64URL.decode),
              let rp = body["rp"] as? [String: Any], let user = body["user"] as? [String: Any],
              let userID = user["id"] as? String, let userHandle = Base64URL.decode(userID), (1...64).contains(userHandle.count),
              let exclude = Self.validCredentialIDs(body["excludeCredentials"])
        else { return reply.fail(.notAllowed) }
        let rpId = ((rp["id"] as? String) ?? context.host).lowercased()
        guard WebAuthnPolicy.isValidRPID(rpId, forHost: context.host, suffixes: VaultService.suffixes) else { return reply.fail(.security) }
        // ES256 is the one algorithm the vault creates; an empty list means ES256 or RS256.
        let algorithms = body["pubKeyCredParams"] as? [Int] ?? []
        guard algorithms.isEmpty || algorithms.contains(-7) else { return reply.fail(.notSupported) }
        guard await service.refresh(profile: context.profile) == .connected else { return reply.fail(.notAllowed) }
        guard reply.isPending else { return }
        guard let presenter = service.presenter, let webView else { return reply.fail(.notAllowed) }

        let userName = user["name"] as? String ?? ""
        let displayName = user["displayName"] as? String ?? ""
        let rpName = (rp["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rpId
        let clientDataJSON = WebAuthnClientData.json(.create, challenge: challenge, origin: context.origin)
        let call = VaultRegister(
            rpId: rpId, rpName: rpName, user: .init(id: userID, name: userName, displayName: displayName),
            clientDataHash: Base64URL.encode(WebAuthnClientData.hash(clientDataJSON)),
            pubKeyCredParams: algorithms.isEmpty ? [-7, -257] : algorithms, excludeCredentials: exclude,
            origin: context.origin, profile: context.profile)
        let shownName = VaultPrompt.displayText(userName.isEmpty ? displayName : userName)
        presenter.confirmPasskeyCreation(rpId: rpId, userName: shownName, in: webView) { confirmed in
            guard confirmed, reply.isPending else { return reply.fail(.notAllowed) }
            Task {
                do {
                    let result = try await service.send(call)
                    reply.succeed([
                        "id": result.credentialId,
                        "clientDataJSON": Base64URL.encode(clientDataJSON),
                        "attestationObject": result.attestationObject,
                        "authenticatorData": result.authenticatorData,
                        "publicKeyAlgorithm": result.publicKeyAlgorithm,
                    ])
                } catch {
                    reply.fail(WebAuthnError(error as? VaultClientError ?? .malformedResponse, creating: true))
                }
            }
        }
    }
}

/// Answers a shim request once; later answers (after an abort or a new document) are dropped.
@MainActor
private final class PasskeyReply {
    private var handler: (@MainActor @Sendable (Any?, String?) -> Void)?

    init(_ handler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        self.handler = handler
    }

    var isPending: Bool { handler != nil }

    func succeed(_ value: [String: Any]) { answer(value) }

    func fail(_ error: WebAuthnError) { answer(["error": error.rawValue]) }

    func finish() { answer(nil) }

    private func answer(_ value: Any?) {
        handler?(value, nil)
        handler = nil
    }
}
#endif
