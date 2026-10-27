import Foundation

/// Something Kobe wants a yes or no on, raised during a chat turn (`approval.request`).
public struct ApprovalRequest: Equatable, Identifiable, Sendable {
    public let runID: String
    public let requestID: String?
    public let command: String?
    public let description: String?

    public init(runID: String, requestID: String?, command: String?, description: String?) {
        self.runID = runID
        self.requestID = requestID
        self.command = command
        self.description = description
    }

    public var id: String { requestID ?? runID }
}

public enum ToolPhase: Equatable, Sendable {
    case started, completed, failed, thinking
}

/// The events of one chat turn that the app cares about. Everything else on the wire is ignored.
public enum ChatEvent: Equatable, Sendable {
    case started(runID: String)
    case delta(String)
    case tool(name: String, phase: ToolPhase, preview: String?)
    case approval(ApprovalRequest)
    case completed(content: String, model: String?)
    case failed(String)
    case cancelled
    case done

    public static func decode(event: String, data: String, copy: Copy = Copy(name: "Kobe")) -> ChatEvent? {
        let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] ?? [:]
        func string(_ key: String) -> String? { json[key] as? String }
        let runID = string("run_id") ?? ""
        switch event {
        case "run.started":
            return .started(runID: runID)
        case "assistant.delta":
            return string("delta").map(ChatEvent.delta)
        case "tool.started", "tool.completed", "tool.failed":
            let phase: ToolPhase = event == "tool.started" ? .started : event == "tool.completed" ? .completed : .failed
            return .tool(name: string("tool_name") ?? "tool", phase: phase, preview: string("preview"))
        case "tool.progress":
            return .tool(name: string("tool_name") ?? "_thinking", phase: .thinking, preview: string("delta"))
        case "approval.request":
            return .approval(ApprovalRequest(runID: runID, requestID: string("request_id"),
                                             command: string("command"), description: string("description")))
        case "assistant.completed":
            return .completed(content: string("content") ?? "", model: model(in: json["runtime"]))
        case "run.failed":
            return .failed(string("error") ?? "\(copy.name) stopped before finishing.")
        case "error":
            return .failed(string("message") ?? "\(copy.name) ran into an error.")
        case "run.cancelled":
            return .cancelled
        case "done":
            return .done
        default:
            return nil
        }
    }

    private static func model(in runtime: Any?) -> String? {
        guard let runtime = runtime as? [String: Any] else { return nil }
        if let model = runtime["model"] as? String, !model.isEmpty { return model }
        if let requested = runtime["requested"] as? [String: Any], let model = requested["model"] as? String, !model.isEmpty { return model }
        return nil
    }
}
