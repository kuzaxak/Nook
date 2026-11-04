// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import NookTabsCore

struct SplitRecordTests {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    @Test func holdsTwoToFourDifferentTabsSideBySideWithEqualPanes() throws {
        #expect(SplitRecord([a]) == nil, "one tab is no split")
        #expect(SplitRecord([a, a]) == nil, "a tab beside itself")
        #expect(SplitRecord([a, b, c, d, e]) == nil, "five panes")
        let pair = try #require(SplitRecord([a, b]))
        #expect(pair.orientation == .horizontal)
        #expect(pair.dividers == [0.5])
        let four = try #require(SplitRecord([a, b, c, d]))
        #expect(four.dividers == [0.25, 0.5, 0.75])
        #expect(four.isFull)
    }

    @Test func insertsBesideAPaneUntilFull() throws {
        let pair = try #require(SplitRecord([a, b]))
        #expect(pair.inserting(c, beside: b, after: true)?.itemIDs == [a, b, c])
        #expect(pair.inserting(c, beside: b, after: false)?.itemIDs == [a, c, b])
        #expect(pair.inserting(c, beside: a, after: false)?.itemIDs == [c, a, b])
        #expect(pair.inserting(c, beside: b, after: true)?.dividers == [1.0 / 3, 2.0 / 3], "panes even out")
        #expect(pair.inserting(a, beside: b, after: true) == nil, "a pane's own tab")
        #expect(pair.inserting(c, beside: d, after: true) == nil, "beside no pane")
        let four = try #require(SplitRecord([a, b, c, d]))
        #expect(four.inserting(e, beside: d, after: true) == nil, "four panes at most")
        #expect(four.inserting(e, at: 4) == nil)
    }

    @Test func replacesAPaneKeepingItsSize() throws {
        var four = try #require(SplitRecord([a, b, c, d]))
        four.moveDivider(0, to: 0.1, minimum: 0.05)
        let replaced = try #require(four.replacing(c, with: e))
        #expect(replaced.itemIDs == [a, b, e, d])
        #expect(replaced.dividers == four.dividers)
        #expect(four.replacing(c, with: a) == nil, "a tab already in a pane")
    }

    @Test func movesAPaneBesideAnother() throws {
        let three = try #require(SplitRecord([a, b, c]))
        #expect(three.moving(a, beside: c, after: true)?.itemIDs == [b, c, a])
        #expect(three.moving(c, beside: a, after: false)?.itemIDs == [c, a, b])
        #expect(three.moving(a, beside: c, after: false)?.itemIDs == [b, a, c])
        #expect(three.moving(a, beside: b, after: false) == nil, "already there")
        #expect(three.moving(b, beside: a, after: true) == nil, "already there")
        #expect(three.moving(a, beside: a, after: true) == nil, "beside itself")
        #expect(three.moving(d, beside: a, after: true) == nil, "not a pane")
        // Move Left and Move Right, Up and Down when stacked.
        #expect(three.moving(b, by: -1)?.itemIDs == [b, a, c])
        #expect(three.moving(b, by: 1)?.itemIDs == [a, c, b])
        #expect(three.moving(a, by: -1) == nil, "at the leading end")
        #expect(three.moving(c, by: 1) == nil, "at the trailing end")
    }

    @Test func separatingTheLastButOnePaneEndsTheSplit() throws {
        let three = try #require(SplitRecord([a, b, c]))
        let pair = try #require(three.removing(b))
        #expect(pair.itemIDs == [a, c])
        #expect(pair.dividers == [0.5])
        #expect(pair.removing(a) == nil, "one tab left is no split")
        #expect(three.removing(d) == three, "not a pane")
    }

    @Test func convertsBetweenSideBySideAndStacked() throws {
        var pair = try #require(SplitRecord([a, b]))
        pair.moveDivider(0, to: 0.3, minimum: 0.1)
        let stacked = pair.converted()
        #expect(stacked.orientation == .vertical)
        #expect(stacked.itemIDs == [a, b] && stacked.dividers == [0.3])
        #expect(stacked.converted().orientation == .horizontal)
    }

    @Test func dividersKeepEveryPaneOpen() throws {
        var three = try #require(SplitRecord([a, b, c]))
        three.moveDivider(0, to: 0.5, minimum: 0.1)
        #expect(three.dividers[0] == 0.5)
        three.moveDivider(0, to: 0.9, minimum: 0.1)
        #expect(abs(three.dividers[0] - (2.0 / 3 - 0.1)) < 1e-9, "stops short of the next divider")
        three.moveDivider(1, to: 0.99, minimum: 0.1)
        #expect(three.dividers[1] == 0.9, "stops short of the trailing edge")
        three.moveDivider(5, to: 0.5, minimum: 0.1)
        #expect(three.dividers.count == 2)
    }

    @Test func aDividerSqueezedByANarrowerWindowStillMoves() throws {
        var three = try #require(SplitRecord([a, b, c]))
        three.moveDivider(0, to: 0.05, minimum: 0.05)
        three.moveDivider(1, to: 0.2, minimum: 0.05)
        #expect(three.dividers == [0.05, 0.2])
        // The window narrowed: a pane now needs 0.3 of it, more than these two have.
        three.moveDivider(0, to: 0, minimum: 0.3)
        #expect(abs(three.dividers[0] - 0.1) < 1e-9, "as far from both neighbours as they allow")
        three.moveDivider(1, to: 0.25, minimum: 0.3)
        #expect(abs(three.dividers[1] - 0.4) < 1e-9)
    }

    @Test func readsTheTwoPaneRecordOfEarlierBuilds() throws {
        let json = #"{"leftItemID":"\#(a.uuidString)","rightItemID":"\#(b.uuidString)","fraction":0.3}"#
        let record = try JSONDecoder().decode(SplitRecord.self, from: Data(json.utf8))
        #expect(record.itemIDs == [a, b])
        #expect(record.dividers == [0.3])
        #expect(record.orientation == .horizontal)
    }

    @Test func savesPanesOrientationAndDividers() throws {
        var three = try #require(SplitRecord([a, b, c], orientation: .vertical))
        three.moveDivider(1, to: 0.8, minimum: 0.1)
        let data = try JSONEncoder().encode(three)
        #expect(try JSONDecoder().decode(SplitRecord.self, from: data) == three)
        // Earlier builds read only the first two panes and the first divider.
        let legacy = try JSONDecoder().decode(LegacySplit.self, from: data)
        #expect(legacy.leftItemID == a && legacy.rightItemID == b && legacy.fraction == three.dividers[0])
    }

    @Test func aWindowKeepsItsOtherStateWhenItsSplitCannotBeRead() throws {
        let window = UUID()
        let json = #"{"id":"\#(window.uuidString)","selectedItemBySpace":[],"split":{"itemIDs":["\#(a.uuidString)"]}}"#
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(json.utf8))
        #expect(record.id == window)
        #expect(record.split == nil)
    }

    @Test func pruningDropsClosedPanesAndEndsASplitLeftWithOne() throws {
        var f = Fixture()
        let tabs = ["one", "two", "three"].map { f.tab($0, in: .tabs(spaceID: f.spaceA)) }
        let gone = UUID()
        var state = DeviceState()
        state.windows = [WindowRecord(split: SplitRecord([tabs[0], gone, tabs[1]])),
                         WindowRecord(split: SplitRecord([tabs[2], gone]))]
        state.prune(against: f.tree)
        #expect(state.windows[0].split?.itemIDs == [tabs[0], tabs[1]])
        #expect(state.windows[1].split == nil)
    }

    private struct LegacySplit: Decodable {
        let leftItemID: UUID
        let rightItemID: UUID
        let fraction: Double
    }
}
