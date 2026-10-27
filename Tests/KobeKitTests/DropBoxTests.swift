import Foundation
import Testing
@testable import KobeKit

struct DropBoxTests {
    let root: URL
    let source: URL
    let box: DropBox
    let day = "2026-10-21"

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("kobe-drop-\(UUID().uuidString)")
        root = base.appendingPathComponent("exchange")
        source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = 21; parts.hour = 12
        let date = Calendar.current.date(from: parts)!
        box = DropBox(root: root, now: { date })
    }

    func file(_ name: String, in folder: String = "", bytes: String = "hello") throws -> URL {
        let dir = folder.isEmpty ? source : source.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes.utf8).write(to: url)
        return url
    }

    var inbox: URL { root.appendingPathComponent("inbox/\(day)") }

    @Test func copiesIntoDatedInbox() throws {
        let result = box.accept([try file("brief.pdf")])
        #expect(result.copied == [inbox.appendingPathComponent("brief.pdf")])
        #expect(try String(contentsOf: result.copied[0], encoding: .utf8) == "hello")
        #expect(result.refused.isEmpty)
    }

    @Test func collisionGetsSuffix() throws {
        let first = box.accept([try file("brief.pdf", in: "a")])
        let second = box.accept([try file("brief.pdf", in: "b")])
        #expect(first.copied[0].lastPathComponent == "brief.pdf")
        #expect(second.copied[0].lastPathComponent == "brief 2.pdf")
    }

    @Test func folderRefused() throws {
        let folder = source.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = box.accept([folder])
        #expect(result.copied.isEmpty)
        #expect(result.refused == [RefusedDrop(name: "photos", reason: .folder)])
    }

    @Test func tooLargeRefused() throws {
        let url = source.appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(DropBox.maxBytes + 1))
        try handle.close()
        #expect(box.accept([url]).refused == [RefusedDrop(name: "big.bin", reason: .tooLarge)])
    }

    @Test func unreadableRefused() throws {
        let url = try file("secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let result = box.accept([url])
        #expect(result.refused == [RefusedDrop(name: "secret.txt", reason: .unreadable)])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: inbox.path)) ?? [] == [])
    }

    @Test func permissionsAreGroupReadable() throws {
        let copied = box.accept([try file("notes.txt")]).copied[0]
        let fileMode = try FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: inbox.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o640)
        #expect(dirMode == 0o750)
    }

    @Test func messageListsPaths() {
        let path = URL(fileURLWithPath: "/tmp/kobe-exchange/inbox/2026-10-21/brief.pdf")
        #expect(DropBox.message(for: [path], text: "Summarise this") ==
            "Summarise this\n\nFiles I dropped for you (in the exchange folder):\n- /tmp/kobe-exchange/inbox/2026-10-21/brief.pdf")
        #expect(DropBox.message(for: [path], text: nil) ==
            "Files I dropped for you (in the exchange folder):\n- /tmp/kobe-exchange/inbox/2026-10-21/brief.pdf")
    }
}
