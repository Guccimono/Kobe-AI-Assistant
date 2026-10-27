import Testing
@testable import KobeKit

@Test func knownToolsRead() {
    #expect(ToolWording.phrase(name: "web_search") == "searching the web…")
    #expect(ToolWording.phrase(name: "search") == "searching the web…")
    #expect(ToolWording.phrase(name: "read_file") == "reading a file…")
    #expect(ToolWording.phrase(name: "file_read") == "reading a file…")
    #expect(ToolWording.phrase(name: "memory_search") == "checking memory…")
    #expect(ToolWording.phrase(name: "terminal") == "running a command…")
    #expect(ToolWording.phrase(name: "bash") == "running a command…")
    #expect(ToolWording.phrase(name: "shell") == "running a command…")
    #expect(ToolWording.phrase(name: "browser_open") == "opening a page…")
    #expect(ToolWording.phrase(name: "mail_read") == "reading your inbox…")
    #expect(ToolWording.phrase(name: "kobe-mac-snapshots") == "reading your inbox…")
    #expect(ToolWording.phrase(name: "calendar_list") == "checking your calendar…")
}

@Test func unknownToolStillReads() {
    #expect(ToolWording.phrase(name: "foo_bar") == "using foo bar…")
    #expect(ToolWording.phrase(name: "foo-bar") == "using foo bar…")
}

@Test func matchesCaseInsensitively() {
    #expect(ToolWording.phrase(name: "Web_Search") == "searching the web…")
    #expect(ToolWording.phrase(name: "BASH") == "running a command…")
}

@Test func shortNames() {
    #expect(ToolWording.short(name: "web_search") == "web search")
    #expect(ToolWording.short(name: "read_file") == "a file")
    #expect(ToolWording.short(name: "memory_search") == "memory")
    #expect(ToolWording.short(name: "terminal") == "a command")
    #expect(ToolWording.short(name: "browser_open") == "a page")
    #expect(ToolWording.short(name: "mail_read") == "your inbox")
    #expect(ToolWording.short(name: "calendar") == "your calendar")
    #expect(ToolWording.short(name: "foo_bar") == "foo bar")
}

@Test func thinkingPhrase() {
    #expect(ToolWording.thinking == "thinking…")
}

@Test func emptyNamesFallBack() {
    #expect(ToolWording.phrase(name: "") == "thinking…")
    #expect(ToolWording.phrase(name: "  ") == "thinking…")
    #expect(ToolWording.short(name: "") == "a tool")
    #expect(ToolWording.short(name: "  ") == "a tool")
}

@Test func containsRulePinned() {
    // Matching is on contains, in table order: the file and chat rows sit above the bare "search".
    #expect(ToolWording.phrase(name: "file_search") == "searching files…")
    #expect(ToolWording.phrase(name: "search_files") == "searching files…")
    #expect(ToolWording.short(name: "search_files") == "files")
    #expect(ToolWording.phrase(name: "session_search") == "searching past chats…")
    #expect(ToolWording.short(name: "session_search") == "past chats")
    #expect(ToolWording.phrase(name: "search") == "searching the web…")
}
