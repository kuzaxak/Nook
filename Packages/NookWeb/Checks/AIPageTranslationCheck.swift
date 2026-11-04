// Licensed under GPL-3.0. See LICENSE.
//
//  AIPageTranslationCheck.swift
//  Nook
//
//  What a page translation sends to an AI model and accepts back, which engine translates a page,
//  and how batches fall back, run side by side and stop. The model is a stand-in, so nothing goes
//  to the network. Compiles the shipped source directly:
//
//    swiftc Packages/NookWeb/Sources/NookWeb/AIPageTranslation.swift \
//           Packages/NookWeb/Sources/NookWeb/TranslationCache.swift \
//           Packages/NookWeb/Checks/AIPageTranslationCheck.swift -o /tmp/ai-page-translation-check && /tmp/ai-page-translation-check
//

import Foundation

@main
struct AIPageTranslationCheck {
    @MainActor
    static func main() async {
        request()
        replies()
        engineChoice()
        await limit()
        await invalidReplies()
        await modelFailure()
        await timeout()
        await batching()
        await caching()
        await parallel()
        await cancellation()
        print("AIPageTranslationCheck passed")
    }

    static let context = AITranslationContext(
        target: Locale.Language(identifier: "en-US"),
        source: Locale.Language(identifier: "de"),
        title: "Die \"Zeit\"\nheute",
        host: "zeit.de"
    )

    static func nodes(_ count: Int, from start: Int = 0) -> [TranslationNode] {
        (start..<start + count).map { TranslationNode(id: String($0), text: "Text \($0)") }
    }

    static func ids(_ range: Range<Int>) -> [String] { range.map(String.init) }

    static func request() {
        let sent = [
            TranslationNode(id: "0", text: "Guten Tag"),
            TranslationNode(id: "7", text: "Preis: 4,99 € auf https://zeit.de/abo")
        ]
        let json = try! JSONSerialization.jsonObject(with: Data(AIPageTranslation.request(for: sent, context: context).utf8)) as! [String: Any]
        precondition(json["target_language"] as? String == "English")
        precondition(json["source_language"] as? String == "German")
        precondition(json["title"] as? String == "Die \"Zeit\"\nheute", "the title goes as data")
        precondition(json["host"] as? String == "zeit.de")
        let texts = json["texts"] as! [[String: Any]]
        precondition(texts.map { $0["id"] as! String } == ["0", "7"], "every id goes, in page order")
        precondition(texts.map { $0["text"] as! String } == sent.map(\.text), "each text goes as it is")

        let traditional = AITranslationContext(target: Locale.Language(identifier: "zh-Hant"), source: Locale.Language(identifier: "ja"), title: "", host: "")
        let named = try! JSONSerialization.jsonObject(with: Data(AIPageTranslation.request(for: sent, context: traditional).utf8)) as! [String: Any]
        precondition(named["target_language"] as? String == "Chinese, Traditional", "a script that is not the usual one is named")
        precondition(named["source_language"] as? String == "Japanese")
    }

    static func replies() {
        let ids = ["0", "1"]
        func parsed(_ reply: String) -> [String: String] { try! AIPageTranslation.translations(fromReply: reply, ids: ids) }
        func failure(_ reply: String) -> AITranslationFailure? {
            do {
                _ = try AIPageTranslation.translations(fromReply: reply, ids: ids)
                return nil
            } catch {
                return error as? AITranslationFailure
            }
        }

        precondition(parsed(#"{"0": "Good day", "1": "Price"}"#) == ["0": "Good day", "1": "Price"])
        precondition(parsed("```json\n{\"0\": \"Good day\", \"1\": \"Price\"}\n```") == ["0": "Good day", "1": "Price"], "a fenced reply reads")
        precondition(parsed(#"{"0": "a", "1": "b", "9": "stray"}"#) == ["0": "a", "1": "b"], "an id that was not asked for is ignored")
        precondition(parsed(#"{"0": " Good  day\n", "1": "\tPrice "}"#) == ["0": " Good  day\n", "1": "\tPrice "], "whitespace stays as the model wrote it")

        precondition(failure(#"{"0": "a"}"#) == .missingTexts(missing: 1, of: 2))
        precondition(failure(#"{"0": "a", "1": "  "}"#) == .missingTexts(missing: 1, of: 2), "a blank translation counts as missing")
        precondition(failure(#"{"0": "a", "1": 4}"#) == .missingTexts(missing: 1, of: 2), "so does one that is not text")
        precondition(failure("I cannot translate this page.") == .invalidJSON)
        precondition(failure(#"{"0": "a", "1": "b""#) == .invalidJSON, "a reply cut off at the output limit")
        precondition(failure(#"["a", "b"]"#) == .invalidJSON)
    }

    static func engineChoice() {
        let model = AITranslationModel(providerId: "openai", modelId: "gpt-6-luna") { _, _ in "" }
        func choice(_ setting: PageTranslationSetting?, isPrivate: Bool = false) -> String {
            switch TranslationEngineChoice.choose(setting, isPrivate: isPrivate) {
            case .onDevice: return "on device"
            case .ai: return "ai"
            case .onDeviceInstead: return "on device instead"
            }
        }
        precondition(choice(nil) == "on device", "no setting translates on device")
        precondition(choice(.onDevice) == "on device")
        precondition(choice(.ai(model)) == "ai")
        precondition(choice(.ai(model), isPrivate: true) == "on device", "a private window never sends page text")
        precondition(choice(.ai(nil), isPrivate: true) == "on device")
        precondition(choice(.ai(nil)) == "on device instead", "the AI engine without a model translates on device and says why")
    }

    @MainActor
    static func limit() async {
        let model = FakeModel()
        let page = FakePage()
        let translator = AIPageTranslator(model: model.model, context: context, characterLimit: 25, onNotice: page.note)
        let ten = String(repeating: "a", count: 10)
        await translator.translate([
            TranslationNode(id: "0", text: ten),
            TranslationNode(id: "1", text: ten),
            TranslationNode(id: "2", text: ten),
            TranslationNode(id: "3", text: "b")
        ], onDevice: page.onDevice, apply: page.apply)
        let sent = await model.requests()
        precondition(sent == [["0", "1"]], "text past the limit is not sent")
        precondition(Set(page.applied.keys) == ["0", "1"] && page.onDeviceBatches.isEmpty, "and stays in the original")
        precondition(page.notices == [.aiLimitReached(characters: 25)])

        // Text the page adds later is past the limit too.
        await translator.translate([TranslationNode(id: "4", text: "c")], onDevice: page.onDevice, apply: page.apply)
        let sentLater = await model.requests()
        precondition(sentLater.count == 1 && page.applied["4"] == nil)
        precondition(page.notices.count == 1, "the limit is reported once")
    }

    @MainActor
    static func invalidReplies() async {
        let model = FakeModel { ids in ids.first == "40" ? .invalidJSON : ids.first == "80" ? .dropFirst : .translate }
        let page = FakePage()
        let translator = AIPageTranslator(model: model.model, context: context, onNotice: page.note)
        await translator.translate(nodes(120), onDevice: page.onDevice, apply: page.apply)
        let sent = await model.requests()
        precondition(sent.count == 3)
        precondition(Set(page.onDeviceBatches) == [ids(40..<80), ids(80..<120)], "each batch with a bad reply goes on device")
        precondition((0..<40).allSatisfy { page.applied[String($0)] == "EN Text \($0)" }, "the good batch lands from the model")
        precondition((40..<120).allSatisfy { page.applied[String($0)] == "ON Text \($0)" })
        precondition(!page.notices.isEmpty && page.notices.allSatisfy { notice in
            if case .aiFailed(_, onDevice: true) = notice { return true }
            return false
        })

        // A bad reply fails only its own batch: the next text still goes to the model.
        await translator.translate(nodes(40, from: 120), onDevice: page.onDevice, apply: page.apply)
        let sentLater = await model.requests()
        precondition(sentLater.count == 4 && page.applied["120"] == "EN Text 120")
        precondition(!page.appliedTwice)
    }

    @MainActor
    static func modelFailure() async {
        // A rejected key or no network: every later request would fail the same way.
        for failure in [FakeModel.Answer.reject, .offline] {
            let model = FakeModel { ids in ids.first == "0" ? failure : .translate }
            let page = FakePage()
            let translator = AIPageTranslator(model: model.model, context: context, onNotice: page.note)
            await translator.translate(nodes(200), onDevice: page.onDevice, apply: page.apply)
            let sent = await model.requests()
            precondition(sent.count == 3, "after the model cannot be reached, nothing more goes to it")
            precondition((0..<40).allSatisfy { page.applied[String($0)] == "ON Text \($0)" }, "the failed batch goes on device")
            precondition((40..<120).allSatisfy { page.applied[String($0)] == "EN Text \($0)" }, "batches already sent still land")
            precondition((120..<200).allSatisfy { page.applied[String($0)] == "ON Text \($0)" }, "the rest goes on device")
            guard case .aiFailed(let reason, onDevice: true)? = page.notices.last, !reason.isEmpty, !reason.contains("\n") else {
                preconditionFailure("the window says the AI engine failed and why")
            }
        }

        // A server error fails only its batch: the model may answer the next one.
        let model = FakeModel { ids in ids.first == "0" ? .serverError : .translate }
        let page = FakePage()
        let translator = AIPageTranslator(model: model.model, context: context, onNotice: page.note)
        await translator.translate(nodes(200), onDevice: page.onDevice, apply: page.apply)
        let sent = await model.requests()
        precondition(sent.count == 5, "every batch still goes to the model")
        precondition((0..<40).allSatisfy { page.applied[String($0)] == "ON Text \($0)" })
        precondition((40..<200).allSatisfy { page.applied[String($0)] == "EN Text \($0)" })

        // Without an on-device translator (a language pair Apple cannot translate) the text stays.
        let alone = FakePage()
        let failing = AIPageTranslator(model: FakeModel { _ in .reject }.model, context: context, onNotice: alone.note)
        await failing.translate(nodes(10), onDevice: nil, apply: alone.apply)
        precondition(alone.applied.isEmpty)
        guard case .aiFailed(_, onDevice: false)? = alone.notices.last else { preconditionFailure("says the text stays") }
    }

    @MainActor
    static func timeout() async {
        let model = FakeModel { ids in ids.first == "0" ? .hang : .translate }
        let page = FakePage()
        let translator = AIPageTranslator(model: model.model, context: context, timeout: { _ in .milliseconds(80) }, onNotice: page.note)
        let started = ContinuousClock.now
        await translator.translate(nodes(160), onDevice: page.onDevice, apply: page.apply)
        precondition(ContinuousClock.now - started < .seconds(5), "a model that never answers is given up on")
        let cancelled = await model.cancelled()
        precondition(cancelled == 1, "and its request is cancelled")
        precondition((0..<40).allSatisfy { page.applied[String($0)] == "ON Text \($0)" }, "the slow batch goes on device")
        let sent = await model.requests()
        precondition(sent.count == 4 && (40..<160).allSatisfy { page.applied[String($0)] == "EN Text \($0)" },
                     "and the rest of the page keeps going to the model")
        precondition(page.notices == [.aiFailed(reason: AITranslationFailure.timedOut.localizedDescription, onDevice: true)])

        let full = AIPageTranslation.replyTimeout(forCharacters: AIPageTranslation.batchCharacterLimit)
        precondition(full >= .seconds(90), "a full batch leaves time for a thinking model's whole reply")
        precondition(AIPageTranslation.replyTimeout(forCharacters: 100) < full, "a short batch gets less")
        precondition(AIPageTranslation.replyTimeout(forCharacters: 50_000) <= .seconds(300))
    }

    @MainActor
    static func batching() async {
        func grouped(_ nodes: [TranslationNode]) -> [[String]] { AIPageTranslation.batches(nodes).map { $0.map(\.id) } }
        let long = (0..<6).map { TranslationNode(id: String($0), text: String(repeating: "a", count: 1_500)) }
        precondition(grouped(long) == [["0", "1"], ["2", "3"], ["4", "5"]], "long texts fill a batch by characters")
        precondition(AIPageTranslation.batches(nodes(100)).map(\.count) == [40, 40, 20], "short ones by count")
        let huge = [
            TranslationNode(id: "0", text: "Kurz"),
            TranslationNode(id: "1", text: String(repeating: "b", count: 5_000)),
            TranslationNode(id: "2", text: "Kurz")
        ]
        precondition(grouped(huge) == [["0"], ["1"], ["2"]], "a text longer than a batch goes alone")

        let model = FakeModel()
        let page = FakePage()
        var timed: [Int] = []
        let translator = AIPageTranslator(model: model.model, context: context, timeout: { characters in
            timed.append(characters)
            return .seconds(5)
        }, onNotice: page.note)
        await translator.translate(long, onDevice: page.onDevice, apply: page.apply)
        let sent = await model.requests()
        precondition(Set(sent) == [["0", "1"], ["2", "3"], ["4", "5"]])
        precondition(timed == [3_000, 3_000, 3_000], "each batch's time follows its length")
        precondition(page.applied.count == 6)
    }

    @MainActor
    static func caching() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = TranslationCache(fileURL: directory.appendingPathComponent("profile.sqlite"))
        func key(_ text: String) -> String {
            TranslationCache.key(provider: "openai", model: "gpt-6-luna", source: "de", target: "en", text: text)
        }
        await cache.store([key("Text 2"): "Two", key("Text 5"): "Five", key("Text 7"): "Seven"])

        let model = FakeModel()
        let first = FakePage()
        let translator = AIPageTranslator(model: model.model, context: context, cache: cache, onNotice: first.note)
        await translator.translate(nodes(10), onDevice: first.onDevice, apply: first.apply)
        let sent = await model.requests()
        precondition(sent == [["0", "1", "3", "4", "6", "8", "9"]], "only text the cache lacks goes to the model")
        precondition(first.writes.first == ["2", "5", "7"], "hits land first, in page order")
        precondition(first.applied["5"] == "Five" && first.applied["0"] == "EN Text 0" && first.applied.count == 10)

        // The site's next page repeats the text under new ids: none of it goes to the model.
        let next = (0..<10).map { TranslationNode(id: "n\($0)", text: "Text \($0)") }
        let second = FakePage()
        let repeated = AIPageTranslator(model: model.model, context: context, cache: cache, onNotice: second.note)
        await repeated.translate(next, onDevice: second.onDevice, apply: second.apply)
        let sentAgain = await model.requests()
        precondition(sentAgain.count == 1 && second.writes == [next.map(\.id)], "the model's validated replies were kept")
        precondition(second.applied["n0"] == "EN Text 0")

        // Cached text is not sent, so it does not count toward the page's limit.
        let limited = FakePage()
        let small = AIPageTranslator(model: model.model, context: context, characterLimit: 5, cache: cache, onNotice: limited.note)
        await small.translate(next, onDevice: limited.onDevice, apply: limited.apply)
        precondition(limited.applied.count == 10 && limited.notices.isEmpty)

        // A reply that fails validation is not kept, nor is the on-device translation in its place.
        let failing = FakeModel { ids in ids.first == "b0" ? .invalidJSON : .dropFirst }
        let fresh = (0..<80).map { TranslationNode(id: "b\($0)", text: "Fresh \($0)") }
        let third = FakePage()
        let bad = AIPageTranslator(model: failing.model, context: context, cache: cache, onNotice: third.note)
        await bad.translate(fresh, onDevice: third.onDevice, apply: third.apply)
        precondition(third.applied["b0"] == "ON Fresh 0" && third.applied["b41"] == "ON Fresh 41")
        let stored = await cache.translations(for: fresh.map { key($0.text) })
        precondition(stored.isEmpty, "a bad or partial reply and Apple's fallback are not cached")
    }

    @MainActor
    static func parallel() async {
        let model = FakeModel()
        let page = FakePage()
        let translator = AIPageTranslator(model: model.model, context: context, onNotice: page.note)
        await translator.translate(nodes(280), onDevice: page.onDevice, apply: page.apply)
        let requests = await model.requests()
        let mostInFlight = await model.maxInFlight()
        precondition(mostInFlight == 3, "three batches at a time")
        precondition(requests.count == 7 && Set(requests.flatMap { $0 }) == Set(ids(0..<280)))
        precondition(Set(requests[0..<3].map { $0[0] }) == ["0", "40", "80"], "the top of the page goes first")
        precondition(Set(requests[3..<6].map { $0[0] }) == ["120", "160", "200"])
        precondition(requests[6][0] == "240")
        precondition(page.applied.count == 280 && page.onDeviceBatches.isEmpty && page.notices.isEmpty)
    }

    @MainActor
    static func cancellation() async {
        let model = FakeModel { _ in .hang }
        let page = FakePage()
        let translator = AIPageTranslator(model: model.model, context: context, onNotice: page.note)
        let run = Task { @MainActor in
            await translator.translate(nodes(200), onDevice: page.onDevice, apply: page.apply)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while await model.requests().count < 3, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        run.cancel()
        await run.value
        let cancelled = await model.cancelled()
        precondition(cancelled == 3, "cancelling the run cancels the requests in flight")
        let sent = await model.requests()
        precondition(sent.count == 3, "and sends no more")
        precondition(page.applied.isEmpty && page.onDeviceBatches.isEmpty && page.notices.isEmpty, "nothing lands or falls back")

        // The page's run starts again (its tab is shown again): what was not translated goes once.
        await model.answer { _ in .translate }
        await translator.translate([], onDevice: page.onDevice, apply: page.apply)
        precondition(page.applied.count == 200 && !page.appliedTwice)
        let sentAgain = await model.requests()
        precondition(sentAgain.count == 3 + 5)
    }
}

/// A stand-in model that answers each batch as `script` says.
actor FakeModel {
    enum Answer { case translate, dropFirst, invalidJSON, reject, offline, serverError, hang }

    private var script: @Sendable ([String]) -> Answer
    private var sent: [[String]] = []
    private var mostInFlight = 0
    private var cancellations = 0
    private var inFlight = 0

    init(_ script: @escaping @Sendable ([String]) -> Answer = { _ in .translate }) {
        self.script = script
    }

    func answer(_ script: @escaping @Sendable ([String]) -> Answer) {
        self.script = script
    }

    func requests() -> [[String]] { sent }
    func maxInFlight() -> Int { mostInFlight }
    func cancelled() -> Int { cancellations }

    nonisolated var model: AITranslationModel {
        AITranslationModel(providerId: "openai", modelId: "gpt-6-luna") { _, request in try await self.reply(to: request) }
    }

    private func reply(to request: String) async throws -> String {
        let json = try JSONSerialization.jsonObject(with: Data(request.utf8)) as! [String: Any]
        let texts = (json["texts"] as! [[String: String]]).map { ($0["id"]!, $0["text"]!) }
        sent.append(texts.map(\.0))
        let answer = script(texts.map(\.0))
        switch answer {
        case .reject: throw AITranslationModelUnavailable(reason: "Invalid or missing API key")
        case .offline: throw URLError(.notConnectedToInternet)
        case .serverError: throw URLError(.badServerResponse)
        default: break
        }
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        do {
            try await Task.sleep(for: answer == .hang ? .seconds(30) : .milliseconds(30))
        } catch {
            cancellations += 1
            throw error
        }
        switch answer {
        case .translate: return Self.encode(texts)
        case .dropFirst: return Self.encode(Array(texts.dropFirst()))
        default: return "Sure! Here is the page in English."
        }
    }

    private static func encode(_ texts: [(String, String)]) -> String {
        let object = Dictionary(uniqueKeysWithValues: texts.map { ($0.0, "EN " + $0.1) })
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}

/// The page side: what lands in it, what went on device and what the window says.
@MainActor
final class FakePage {
    var applied: [String: String] = [:]
    var appliedTwice = false
    /// The ids of each apply call, in the order they were written to the page.
    var writes: [[String]] = []
    var onDeviceBatches: [[String]] = []
    var notices: [PageTranslationNotice] = []

    func apply(_ pairs: [(id: String, text: String)]) async {
        writes.append(pairs.map(\.id))
        for (id, text) in pairs {
            if applied[id] != nil { appliedTwice = true }
            applied[id] = text
        }
    }

    func onDevice(_ batch: [TranslationNode]) async throws -> [String: String] {
        onDeviceBatches.append(batch.map(\.id))
        return Dictionary(uniqueKeysWithValues: batch.map { ($0.id, "ON " + $0.text) })
    }

    func note(_ notice: PageTranslationNotice) {
        notices.append(notice)
    }
}
