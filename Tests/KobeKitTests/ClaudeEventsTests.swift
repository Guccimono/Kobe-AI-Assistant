import Foundation
import Testing
@testable import KobeKit

@Test func parsesPermission() throws {
    guard case .permission(let p)? = ClaudeEvent.parse(StubURLProtocol.fixture("hook_permission_bash.json")) else {
        Issue.record("not a permission"); return
    }
    #expect(p.title == "Run a command")
    #expect(p.body == "rm -rf build")
    #expect(p.detail == "Clean the build folder")
    #expect(p.project == "kobe")
}

@Test func parsesQuestion() {
    let event = ClaudeEvent.parse(StubURLProtocol.fixture("hook_question.json"))
    #expect(event == .question(ClaudeQuestion(project: "kobe", question: "Which approach should I take?", options: ["Fix it here", "New session", "Skip"])))
}

@Test func stopIsFinished() {
    #expect(ClaudeEvent.parse(StubURLProtocol.fixture("hook_stop.json")) == .finished(project: "kobe", app: "VS Code"))
}

@Test func toolUseIsAStep() {
    let json = #"{"hook_event_name":"PreToolUse","cwd":"/x/site","tool_name":"Edit","tool_input":{}}"#
    #expect(ClaudeEvent.parse(Data(json.utf8)) == .step(project: "site", step: .editing))
}

@Test func garbageIsIgnored() {
    #expect(ClaudeEvent.parse(Data("not json".utf8)) == nil)
}

@Test func hiddenCharactersAreShown() {
    #expect(ClaudeText.visible("rm\u{202E}x") == "rm⟨U+202E⟩x")
}

@Test func questionWithoutTheAskFlagIsJustAStep() throws {
    var json = try JSONSerialization.jsonObject(with: StubURLProtocol.fixture("hook_question.json")) as! [String: Any]
    json.removeValue(forKey: "_ask")
    let data = try JSONSerialization.data(withJSONObject: json)
    #expect(ClaudeEvent.parse(data) == .step(project: "kobe", step: .working))
}

@Test func questionKeepsTheRawTextForTheWire() throws {
    let json = """
    {"hook_event_name":"PreToolUse","cwd":"/x/site","tool_name":"AskUserQuestion","_ask":true,"tool_input":{"questions":[
      {"question":"Deploy\\u00a0now?","options":[{"label":"Yes\\u2714\\ufe0f"},{"label":"No"}]}]}}
    """
    guard case .question(let q)? = ClaudeEvent.parse(Data(json.utf8)) else { Issue.record("not a question"); return }
    #expect(q.question == "Deploy⟨U+00A0⟩now?")
    #expect(q.rawQuestion == "Deploy\u{00A0}now?")
    #expect(q.options == ["Yes✔⟨U+FE0F⟩", "No"])
    #expect(q.rawOptions == ["Yes✔\u{FE0F}", "No"])
    #expect(q.rawLabel(for: "Yes✔⟨U+FE0F⟩") == "Yes✔\u{FE0F}")
    #expect(q.count == 1)
}

@Test func severalQuestionsAreCountedSoTheNotchAnswersNone() throws {
    let json = """
    {"hook_event_name":"PreToolUse","cwd":"/x/site","tool_name":"AskUserQuestion","_ask":true,"tool_input":{"questions":[
      {"question":"A?","options":[{"label":"1"}]},{"question":"B?","options":[{"label":"2"}]}]}}
    """
    guard case .question(let q)? = ClaudeEvent.parse(Data(json.utf8)) else { Issue.record("not a question"); return }
    #expect(q.count == 2)
    #expect(q.question == "A?")
}
