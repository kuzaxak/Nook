// Licensed under GPL-3.0. See LICENSE.
//
//  VaultBridge.swift
//  Nook
//
//  One web view's link to Pawl Vault. Passwords and one-time codes: the form script and its
//  handler live in the isolated NookAutofill world; Nook shows the accounts for the frame's
//  origin (for a code field, those with a code) and fills through that world after the user
//  picks one. Passkeys: while the vault is connected or security keys are on, a page-world
//  shim replaces the suppression script and posts to the reply handler `nookPasskey`; with
//  both, a sheet first asks which to use. The origin always comes from WebKit's frame info,
//  and nothing is signed or filled without Nook's own picker, confirmation or sheet first.
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
    private static let vaultPasskeySource = passkeySource.replacingOccurrences(of: "__NOOK_PLATFORM__", with: "true")
    private static let securityKeyPasskeySource = passkeySource.replacingOccurrences(of: "__NOOK_PLATFORM__", with: "false")
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
    /// Passkey requests not yet answered.
    private var requests = PasskeyLedger<PasskeyReply>()
    /// `mediation: "conditional"` requests, offered when a webauthn field takes focus.
    private var conditionalGets: [PasskeyRequestKey: GetRequest] = [:]
    /// Orders requests; the newest conditional one is offered.
    private var requestSerial = 0
    /// The request whose picker is open.
    private var modalGetID: PasskeyRequestKey?
    /// Token of the picker this bridge has open; a stale picker's completion never clears a newer one.
    private var openPicker: Int?
    private var pickerCount = 0
    /// Bumped by every open request and close, so a slow vault lookup cannot open a picker late.
    private var focusGeneration = 0
    /// The main frame's origin as of its last commit; a subframe must match it.
    private var committedOrigin: String?
    /// The security key request's sheet, and its ceremony once one runs.
    private var keyRequest: (id: PasskeyRequestKey, sheet: SecurityKeySheet, ceremony: SecurityKeyCeremony?)?

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
    /// connected or security keys are on, the suppression script otherwise. The shim offers a
    /// platform authenticator only with the vault. Scripts apply from the next document.
    private func syncScripts() {
        guard let controller, let service else { return }
        let autofill = service.isEnabled
        let passkeys = service.isConnected || service.securityKeysEnabled
        let shim = service.isConnected ? Self.vaultPasskeySource : Self.securityKeyPasskeySource
        // Read the bridged array fully before removeAllUserScripts() (Release-only trap).
        let all = Array(controller.userScripts)
        func has(_ marker: String) -> Bool { all.contains { $0.source.hasPrefix(marker) } }
        let passkeyScriptCurrent = passkeys
            ? all.contains { $0.source == shim }
            : has(Self.suppressionMarker) && !has(Self.passkeyMarker)
        if has(Self.autofillMarker) != autofill || !passkeyScriptCurrent {
            let ours = [Self.autofillMarker, Self.passkeyMarker, Self.suppressionMarker]
            let keep = all.nookOwned.filter { script in !ours.contains { script.source.hasPrefix($0) } }
            controller.removeAllUserScripts()
            keep.forEach(controller.addUserScript)
            controller.addUserScript(passkeys
                ? WKUserScript(source: shim, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
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
        if !service.isConnected { endVaultRequests() }
        if !service.securityKeysEnabled { endKeyRequest() }
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
        requests.removeAll().forEach { $0.fail(error) }
        conditionalGets = [:]
        modalGetID = nil
        endKeyRequest()
    }

    /// The vault disconnected: its requests end and its picker closes; a security key request goes on.
    private func endVaultRequests() {
        requests.removeVault().forEach { $0.fail(.notAllowed) }
        conditionalGets = [:]
        modalGetID = nil
        closePicker()
    }

    /// Cancels the security key ceremony or choice under way; its sheet then closes.
    private func endKeyRequest() {
        guard let request = keyRequest else { return }
        keyRequest = nil
        request.ceremony?.cancel()
        request.sheet.interrupt()
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
        let conditional = webauthn && !code ? conditionalGets.values.filter { $0.origin == origin }.max { $0.serial < $1.serial } : nil
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

    private func picked(_ item: VaultPickerItem?, frame: WKFrameInfo, origin: String, conditionalID: PasskeyRequestKey?,
                        in webView: WKWebView) {
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
        let id: PasskeyRequestKey
        let serial: Int
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
              let token = body["requestId"] as? String
        else { return reply.fail(.notAllowed) }

        requests.prune { $0.isPending }
        switch op {
        case "abort":
            guard case .success(let context) = context(for: message, body),
                  let requestID = PasskeyRequestKey(origin: context.origin, token: token)
            else { return reply.finish() }
            requests.remove(requestID)?.fail(.abort)
            conditionalGets.removeValue(forKey: requestID)
            if modalGetID == requestID { closePicker() }
            if keyRequest?.id == requestID { endKeyRequest() }
            reply.finish()
        case "get", "create":
            let context: PageContext
            switch self.context(for: message, body) {
            case .success(let value): context = value
            case .failure(let error): return reply.fail(error)
            }
            guard let requestID = PasskeyRequestKey(origin: context.origin, token: token), let route = route(op, body),
                  requests.admit(requestID, kind: route == .vault ? .vault : .securityKey, reply: reply) == nil
            else { return reply.fail(.notAllowed) }
            let origin = message.frameInfo.securityOrigin
            Task {
                switch route {
                case .vault: await vault(op, body, id: requestID, context: context, reply: reply)
                case .securityKey: await securityKey(op, body, id: requestID, origin: origin, context: context, reply: reply)
                case .choice: await choose(op, body, id: requestID, origin: origin, context: context, reply: reply)
                }
            }
        default:
            reply.fail(.notAllowed)
        }
    }

    private enum Route {
        case vault, securityKey, choice
    }

    /// Conditional requests are the vault's; with security keys on, the rest go to a key, or
    /// to a choice between the two while the vault is connected. An attachment the page names
    /// settles it.
    private func route(_ op: String, _ body: [String: Any]) -> Route? {
        guard let service else { return nil }
        let vault: Route? = service.isEnabled ? .vault : nil
        if op == "get", body["mediation"] as? String == "conditional" { return vault }
        guard service.securityKeysEnabled else { return vault }
        guard service.isConnected else { return .securityKey }
        switch (body["authenticatorSelection"] as? [String: Any])?["authenticatorAttachment"] as? String {
        case "platform" where op == "create": return .vault
        case "cross-platform" where op == "create": return .securityKey
        default: return .choice
        }
    }

    private func vault(_ op: String, _ body: [String: Any], id: PasskeyRequestKey, context: PageContext, reply: PasskeyReply) async {
        if op == "get" {
            await get(body, id: id, context: context, reply: reply)
        } else {
            await create(body, context: context, reply: reply)
        }
    }

    /// Origin from WebKit; the main frame or a frame with its origin and none other above it;
    /// HTTPS or local HTTP.
    private func context(for message: WKScriptMessage, _ body: [String: Any]) -> Result<PageContext, WebAuthnError> {
        guard let service, service.isEnabled || service.securityKeysEnabled, let webView = message.webView else { return .failure(.notAllowed) }
        let security = message.frameInfo.securityOrigin
        guard let origin = WebAuthnPolicy.origin(scheme: security.protocol, host: security.host, port: security.port)
        else { return .failure(.security) }
        guard WebAuthnPolicy.isAllowedFrame(isMainFrame: message.frameInfo.isMainFrame, frameOrigin: origin,
                                            mainFrameOrigin: committedOrigin, ancestorOrigins: body["ancestorOrigins"] as? [String])
        else { return .failure(.notAllowed) }
        guard WebAuthnPolicy.isAllowedOrigin(scheme: security.protocol, host: security.host) else { return .failure(.security) }
        return .success(PageContext(origin: origin, host: security.host.lowercased(), profile: profile))
    }

    private static func validCredentialIDs(_ value: Any?) -> [String]? {
        let ids = value as? [String] ?? []
        return ids.allSatisfy({ Base64URL.decode($0) != nil }) ? ids : nil
    }

    private func get(_ body: [String: Any], id: PasskeyRequestKey, context: PageContext, reply: PasskeyReply) async {
        guard let service, let challenge = (body["challenge"] as? String).flatMap(Base64URL.decode),
              let allow = Self.validCredentialIDs(body["allowCredentials"])
        else { return reply.fail(.notAllowed) }
        let rpId = ((body["rpId"] as? String) ?? context.host).lowercased()
        guard WebAuthnPolicy.isValidRPID(rpId, forHost: context.host, suffixes: VaultService.suffixes) else { return reply.fail(.security) }
        guard await service.refresh(profile: context.profile) == .connected else { return reply.fail(.notAllowed) }

        let requested = body["userVerification"] as? String ?? ""
        requestSerial += 1
        let request = GetRequest(
            id: id, serial: requestSerial, rpId: rpId, allowCredentials: allow,
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

extension VaultBridge {
    // MARK: - Security keys

    /// "Pawl Vault" or "Security key" on the sheet; the vault's own flow runs unchanged.
    private func choose(_ op: String, _ body: [String: Any], id: PasskeyRequestKey, origin: WKSecurityOrigin, context: PageContext,
                        reply: PasskeyReply) async {
        guard let presenter = service?.securityKeyPresenter, let webView else {
            requests.securityKeyEnded(id)
            return reply.fail(.notAllowed)
        }
        let sheet = SecurityKeySheet(host: context.host, creating: op == "create")
        guard presenter.present(sheet, in: webView) else {
            requests.securityKeyEnded(id)
            return reply.fail(.notAllowed)
        }
        keyRequest = (id, sheet, nil)
        let answer = await sheet.ask(.choose)
        let current = keyRequest?.id == id && reply.isPending
        if case .securityKey? = answer, current {
            return await securityKey(op, body, id: id, origin: origin, context: context, reply: reply, sheet: sheet)
        }
        if keyRequest?.id == id { keyRequest = nil }
        presenter.dismiss(sheet)
        guard case .vault? = answer, current else {
            requests.securityKeyEnded(id)
            return reply.fail(.notAllowed)
        }
        requests.becameVault(id)
        await vault(op, body, id: id, context: context, reply: reply)
    }

    /// One ceremony with the keys plugged in, on `chosen` or a new sheet. The request is built
    /// from WebKit's origin for the frame and checked before any sheet appears.
    private func securityKey(_ op: String, _ body: [String: Any], id: PasskeyRequestKey, origin: WKSecurityOrigin, context: PageContext,
                             reply: PasskeyReply, sheet chosen: SecurityKeySheet? = nil) async {
        let presenter = service?.securityKeyPresenter
        func end(_ error: WebAuthnError) {
            chosen.map { presenter?.dismiss($0) }
            if keyRequest?.id == id { keyRequest = nil }
            requests.securityKeyEnded(id)
            reply.fail(error)
        }
        let request: SecurityKeyCeremony.Request
        let clientDataJSON: Data
        var credProps = false
        if op == "get" {
            switch SecurityKeyOptions.get(body, scheme: origin.protocol, host: origin.host, port: origin.port,
                                          suffixes: VaultService.suffixes) {
            case .success(let value):
                request = .get(value)
                clientDataJSON = value.clientDataJSON
            case .failure(let error):
                return end(error)
            }
        } else {
            switch SecurityKeyOptions.create(body, scheme: origin.protocol, host: origin.host, port: origin.port,
                                             suffixes: VaultService.suffixes) {
            case .success(let value):
                request = .create(value)
                clientDataJSON = value.clientDataJSON
                credProps = value.credProps
            case .failure(let error):
                return end(error)
            }
        }

        let sheet = chosen ?? SecurityKeySheet(host: context.host, creating: op == "create")
        guard reply.isPending, !SecurityKeyCeremony.isRunning, let presenter, let webView,
              chosen != nil || presenter.present(sheet, in: webView)
        else { return end(.notAllowed) }
        let ceremony = SecurityKeyCeremony(request, source: HIDSecurityKeySource(), user: sheet)
        sheet.onCancel = { [weak ceremony] in ceremony?.cancel() }
        keyRequest = (id, sheet, ceremony)
        let result = await ceremony.run()
        presenter.dismiss(sheet)
        if keyRequest?.id == id { keyRequest = nil }
        requests.securityKeyEnded(id)
        switch result {
        case .success(.created(let credential)):
            reply.succeed(SecurityKeyReply.created(credential, clientDataJSON: clientDataJSON, credProps: credProps))
        case .success(.asserted(let assertion)):
            reply.succeed(SecurityKeyReply.asserted(assertion, clientDataJSON: clientDataJSON))
        case .failure(let error):
            reply.fail(error)
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
