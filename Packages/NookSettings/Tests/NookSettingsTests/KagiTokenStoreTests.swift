// Licensed under GPL-3.0. See LICENSE.
import Testing
@testable import NookSettings

final class CountingKagiTokenStore: KagiTokenStore, @unchecked Sendable {
    var stored: String?
    private(set) var loads = 0

    init(stored: String? = nil) { self.stored = stored }

    func load() -> String? {
        loads += 1
        return stored
    }

    func save(_ token: String?) { stored = token }
}

@MainActor
struct KagiTokenStoreTests {
    @Test func creatingSettingsReadsNoToken() {
        let store = CountingKagiTokenStore(stored: "abc")
        _ = NookSettingsService(kagiTokenStore: store)
        #expect(store.loads == 0)
    }

    @Test func firstUseReadsOnceAndKeepsTheToken() {
        let store = CountingKagiTokenStore(stored: "abc")
        let settings = NookSettingsService(kagiTokenStore: store)
        #expect(settings.kagiSessionToken == "abc")
        #expect(settings.kagiSessionToken == "abc")
        #expect(store.loads == 1)
    }

    @Test func kagiSearchTemplateReadsTheTokenOnlyForKagi() {
        let store = CountingKagiTokenStore(stored: "abc")
        let settings = NookSettingsService(kagiTokenStore: store)
        #expect(settings.searchTemplate(for: SearchProvider.google.rawValue) == SearchProvider.google.queryTemplate)
        #expect(store.loads == 0)
        #expect(settings.searchTemplate(for: SearchProvider.kagi.rawValue) == KagiSession.searchTemplate(token: "abc"))
        #expect(store.loads == 1)
    }

    @Test func savingReplacesTheTokenWithoutReading() {
        let store = CountingKagiTokenStore(stored: "old")
        let settings = NookSettingsService(kagiTokenStore: store)
        settings.setKagiSession("new")
        #expect(settings.kagiSessionToken == "new")
        #expect(store.stored == "new")
        settings.setKagiSession(nil)
        #expect(settings.kagiSessionToken == nil)
        #expect(store.stored == nil)
        #expect(store.loads == 0)
    }
}
