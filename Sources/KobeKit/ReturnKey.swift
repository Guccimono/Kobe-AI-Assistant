/// What Return does in a message field: send it, or start a new line (Shift or Option held).
public enum ReturnKey: Equatable, Sendable {
    case send, newline

    public static func action(shift: Bool, option: Bool) -> ReturnKey {
        shift || option ? .newline : .send
    }
}
