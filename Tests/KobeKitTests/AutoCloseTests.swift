import Testing
@testable import KobeKit

@Test func permissionNeverFolds() {
    #expect(!AutoClose.shouldFold(overlay: .permission, shownFor: 999, setting: 10, hovering: false, pinned: false))
    #expect(!AutoClose.shouldFold(overlay: .question, shownFor: 999, setting: 10, hovering: false, pinned: false))
}

@Test func finishedFoldsAfterSetting() {
    #expect(!AutoClose.shouldFold(overlay: .finished, shownFor: 14.9, setting: 15, hovering: false, pinned: false))
    #expect(AutoClose.shouldFold(overlay: .finished, shownFor: 15, setting: 15, hovering: false, pinned: false))
    #expect(AutoClose.shouldFold(overlay: .notification, shownFor: 30, setting: 30, hovering: false, pinned: false))
}

@Test func hoverHolds() {
    #expect(!AutoClose.shouldFold(overlay: .finished, shownFor: 60, setting: 10, hovering: true, pinned: false))
}

@Test func pinnedHolds() {
    #expect(!AutoClose.shouldFold(overlay: .finished, shownFor: 60, setting: 10, hovering: false, pinned: true))
}

@Test func otherViewsNeverFold() {
    #expect(!AutoClose.shouldFold(overlay: .quickAsk, shownFor: 60, setting: 10, hovering: false, pinned: false))
    #expect(!AutoClose.shouldFold(overlay: .none, shownFor: 60, setting: 10, hovering: false, pinned: false))
}
