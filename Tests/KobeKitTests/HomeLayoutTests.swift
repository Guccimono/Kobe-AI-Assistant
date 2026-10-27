import Foundation
import Testing
@testable import KobeKit

struct HomeLayoutTests {
    @Test func unfoldsForAnythingWaitingInTheChat() {
        #expect(!HomeLayout.shouldUnfold(needsAnswer: false, dropPending: false, replyNotice: false, focusRequested: false))
        #expect(HomeLayout.shouldUnfold(needsAnswer: true, dropPending: false, replyNotice: false, focusRequested: false))
        #expect(HomeLayout.shouldUnfold(needsAnswer: false, dropPending: true, replyNotice: false, focusRequested: false))
        #expect(HomeLayout.shouldUnfold(needsAnswer: false, dropPending: false, replyNotice: true, focusRequested: false))
        #expect(HomeLayout.shouldUnfold(needsAnswer: false, dropPending: false, replyNotice: false, focusRequested: true))
    }

    @Test func railBadgeWhenSomethingWaits() {
        #expect(!HomeLayout.railBadge(needsAnswer: false, dropPending: false))
        #expect(HomeLayout.railBadge(needsAnswer: true, dropPending: false))
        #expect(HomeLayout.railBadge(needsAnswer: false, dropPending: true))
    }

    // MARK: Writing first

    @Test func homeOpensWritingFirstWhenNothingWaits() {
        #expect(HomeLayout.opening(.writing, needsYou: 0, needsAnswer: false) == .writing)
        #expect(HomeLayout.opening(.writing, needsYou: 2, needsAnswer: false) == .split)
        #expect(HomeLayout.opening(.writing, needsYou: 0, needsAnswer: true) == .split)
        #expect(HomeLayout.opening(.split, needsYou: 0, needsAnswer: false) == .split)
        #expect(HomeLayout.opening(.now, needsYou: 0, needsAnswer: false) == .reading)
        // An approval lives in the chat: Now first never hides it.
        #expect(HomeLayout.opening(.now, needsYou: 3, needsAnswer: true) == .split)
    }

    @Test func typingFoldsNow() {
        #expect(HomeLayout.afterTyping(.split, foldOnType: true) == .writing)
        #expect(HomeLayout.afterTyping(.split, foldOnType: false) == .split)
        #expect(HomeLayout.afterTyping(.writing, foldOnType: true) == .writing)
        #expect(HomeLayout.afterTyping(.reading, foldOnType: true) == .reading)
    }

    @Test func theFieldGrowsWhileWriting() {
        #expect(HomeLayout.composerLines(.writing) == 1...10)
        #expect(HomeLayout.composerLines(.split) == 1...5)
    }

    @Test func startChoices() {
        #expect(HomeStart.allCases.map(\.label) == ["Writing first", "Split", "Now first"])
    }

    @Test func commandBackslashAndEscape() {
        #expect(HomeLayout.toggled(.split) == .writing)
        #expect(HomeLayout.toggled(.writing) == .split)
        #expect(HomeLayout.toggled(.reading) == .split)
        // Esc mid-draft brings Now back first; an empty field, or any other mode, closes as before.
        #expect(HomeLayout.escape(.writing, hasDraft: true) == .split)
        #expect(HomeLayout.escape(.writing, hasDraft: false) == nil)
        #expect(HomeLayout.escape(.split, hasDraft: true) == nil)
        #expect(HomeLayout.escape(.reading, hasDraft: true) == nil)
    }

    @Test func somethingWaitingInTheChatOpensItAnyway() {
        #expect(HomeLayout.opening(.now, needsYou: 0, needsAnswer: false, chatWaiting: true) == .split)
        #expect(HomeLayout.opening(.writing, needsYou: 0, needsAnswer: false, chatWaiting: true) == .writing)
    }

    @MainActor @Test func homeSettingsPersist() {
        let suite = "HomeLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.homeStart == .writing && settings.foldNowOnType)
        settings.homeStart = .now
        settings.foldNowOnType = false
        let again = AppSettings(defaults: defaults)
        #expect(again.homeStart == .now && !again.foldNowOnType)
    }
}
