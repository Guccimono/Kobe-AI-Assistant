import Testing
@testable import KobeKit

struct ReturnKeyTests {
    @Test func returnSendsShiftOrOptionAddsALine() {
        #expect(ReturnKey.action(shift: false, option: false) == .send)
        #expect(ReturnKey.action(shift: true, option: false) == .newline)
        #expect(ReturnKey.action(shift: false, option: true) == .newline)
        #expect(ReturnKey.action(shift: true, option: true) == .newline)
    }
}
