import Testing
import Foundation
import DiffKit
@testable import AppCore

private func line(_ kind: DiffLineKind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String = "") -> DiffLine {
    DiffLine(kind: kind, oldNumber: oldNumber, newNumber: newNumber, text: text)
}

@Test func contextLinesAppearOnBothSides() {
    let pairs = SplitDiffPairer.pair([
        line(.context, oldNumber: 1, newNumber: 1, text: "a"),
        line(.context, oldNumber: 2, newNumber: 2, text: "b")
    ])
    #expect(pairs.count == 2)
    #expect(pairs[0].left?.text == "a")
    #expect(pairs[0].right?.text == "a")
    #expect(pairs[1].left?.text == "b")
    #expect(pairs[1].right?.text == "b")
}

@Test func removedFollowedByAddedPairsTogether() {
    let pairs = SplitDiffPairer.pair([
        line(.removed, oldNumber: 1, text: "old"),
        line(.added, newNumber: 1, text: "new")
    ])
    #expect(pairs.count == 1)
    #expect(pairs[0].left?.text == "old")
    #expect(pairs[0].right?.text == "new")
}

@Test func consecutiveRemovedsQueueAndPairWithFollowingAddeds() {
    let pairs = SplitDiffPairer.pair([
        line(.removed, oldNumber: 1, text: "r1"),
        line(.removed, oldNumber: 2, text: "r2"),
        line(.added, newNumber: 1, text: "a1"),
        line(.added, newNumber: 2, text: "a2")
    ])
    #expect(pairs.count == 2)
    #expect(pairs[0].left?.text == "r1")
    #expect(pairs[0].right?.text == "a1")
    #expect(pairs[1].left?.text == "r2")
    #expect(pairs[1].right?.text == "a2")
}

@Test func pureRemovedHunkRendersLeftOnly() {
    let pairs = SplitDiffPairer.pair([
        line(.removed, oldNumber: 1, text: "r1"),
        line(.removed, oldNumber: 2, text: "r2")
    ])
    #expect(pairs.count == 2)
    #expect(pairs[0].left?.text == "r1")
    #expect(pairs[0].right == nil)
    #expect(pairs[1].left?.text == "r2")
    #expect(pairs[1].right == nil)
}

@Test func pureAddedHunkRendersRightOnly() {
    let pairs = SplitDiffPairer.pair([
        line(.added, newNumber: 1, text: "a1"),
        line(.added, newNumber: 2, text: "a2")
    ])
    #expect(pairs.count == 2)
    #expect(pairs[0].left == nil)
    #expect(pairs[0].right?.text == "a1")
    #expect(pairs[1].left == nil)
    #expect(pairs[1].right?.text == "a2")
}

@Test func contextSeparatesRemovedFromAddedBatches() {
    let pairs = SplitDiffPairer.pair([
        line(.removed, oldNumber: 1, text: "r1"),
        line(.context, oldNumber: 2, newNumber: 1, text: "ctx"),
        line(.added, newNumber: 2, text: "a1")
    ])
    #expect(pairs.count == 3)
    #expect(pairs[0].left?.text == "r1")
    #expect(pairs[0].right == nil)
    #expect(pairs[1].left?.text == "ctx")
    #expect(pairs[1].right?.text == "ctx")
    #expect(pairs[2].left == nil)
    #expect(pairs[2].right?.text == "a1")
}

@Test func addedWithoutRemovedRendersRightOnly() {
    let pairs = SplitDiffPairer.pair([
        line(.context, oldNumber: 1, newNumber: 1, text: "ctx"),
        line(.added, newNumber: 2, text: "new")
    ])
    #expect(pairs.count == 2)
    #expect(pairs[0].left?.text == "ctx")
    #expect(pairs[0].right?.text == "ctx")
    #expect(pairs[1].left == nil)
    #expect(pairs[1].right?.text == "new")
}

@Test func leftoverRemovedsAtEndRenderLeftOnly() {
    let pairs = SplitDiffPairer.pair([
        line(.added, newNumber: 1, text: "new"),
        line(.removed, oldNumber: 1, text: "r1"),
        line(.removed, oldNumber: 2, text: "r2")
    ])
    #expect(pairs.count == 3)
    #expect(pairs[0].left == nil)
    #expect(pairs[0].right?.text == "new")
    #expect(pairs[1].left?.text == "r1")
    #expect(pairs[1].right == nil)
    #expect(pairs[2].left?.text == "r2")
    #expect(pairs[2].right == nil)
}
