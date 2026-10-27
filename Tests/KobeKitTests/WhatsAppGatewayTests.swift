import Foundation
import Testing
@testable import KobeKit

@Suite struct WhatsAppWebhookTests {
    @Test func signsAndVerifiesBothGateways() {
        let body = Data(#"{"event":"message"}"#.utf8)
        let signature = WAWebhook.signature(body: body, secret: "s3cret")
        #expect(signature.hasPrefix("sha256=") && signature.count == 71)
        // RFC 4231-style check against a known HMAC-SHA256.
        #expect(WAWebhook.signature(body: Data("The quick brown fox jumps over the lazy dog".utf8), secret: "key")
                == "sha256=f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        #expect(WAWebhook.verify(kind: .gowa, headers: ["x-hub-signature-256": signature], body: body, secret: "s3cret"))
        #expect(WAWebhook.verify(kind: .openwa, headers: ["x-openwa-signature": signature], body: body, secret: "s3cret"))
        #expect(!WAWebhook.verify(kind: .gowa, headers: ["x-openwa-signature": signature], body: body, secret: "s3cret"))
        #expect(!WAWebhook.verify(kind: .gowa, headers: ["x-hub-signature-256": signature], body: body + Data(" ".utf8), secret: "s3cret"))
        #expect(!WAWebhook.verify(kind: .gowa, headers: ["x-hub-signature-256": signature], body: body, secret: ""))
        #expect(!WAWebhook.verify(kind: .gowa, headers: ["x-hub-signature-256": String(signature.dropFirst(7))], body: body, secret: "s3cret"))
        #expect(waConstantTimeEqual("abc", "abc") && !waConstantTimeEqual("abc", "abd") && !waConstantTimeEqual("abc", "ab"))
    }

    @Test func listenerStatusChecksPathMethodAndSignature() {
        let body = Data("{}".utf8)
        let sig = WAWebhook.signature(body: body, secret: "k")
        let ok = WAHTTPRequest(method: "POST", path: "/whatsapp", headers: ["x-hub-signature-256": sig], body: body)
        #expect(WAWebhook.status(for: ok, kind: .gowa, secret: "k") == 200)
        #expect(WAWebhook.status(for: ok, kind: .openwa, secret: "k") == 401)
        var wrongPath = ok
        wrongPath.path = "/other"
        #expect(WAWebhook.status(for: wrongPath, kind: .gowa, secret: "k") == 404)
        var get = ok
        get.method = "GET"
        #expect(WAWebhook.status(for: get, kind: .gowa, secret: "k") == 404)
    }

    @Test func parsesGOWAMessages() throws {
        let event = WAWebhook.parse(kind: .gowa, body: StubURLProtocol.fixture("gowa_webhook_message.json"))
        guard case .message(let m)? = event else { Issue.record("no message"); return }
        #expect(m.id == "3EB0A1")
        #expect(m.chat == "15550001111@s.whatsapp.net")
        #expect(m.senderName == "Ana Lima")
        #expect(m.text == "See you at 6?")
        #expect(m.media == .none)
        #expect(!m.fromMe && !m.mentionsMe)
        #expect(m.date == WADate.rfc3339("2026-10-21T16:43:00Z"))

        guard case .message(let g)? = WAWebhook.parse(kind: .gowa, body: StubURLProtocol.fixture("gowa_webhook_group.json")) else {
            Issue.record("no group message"); return
        }
        #expect(g.media == .image)
        #expect(g.senderName == "Bruno")
        #expect(g.mentionsMe)   // the device_id names this account
        #expect(g.date == WADate.rfc3339("2026-10-21T16:44:00.123Z"))

        #expect(WAWebhook.parse(kind: .gowa, body: StubURLProtocol.fixture("gowa_webhook_receipt.json")) == .ignored)
        #expect(WAWebhook.parse(kind: .gowa, body: Data("not json".utf8)) == nil)
    }

    @Test func gowaMediaKeys() {
        #expect(WAWebhook.gowaMedia(["video_note": 1]) == .video)
        #expect(WAWebhook.gowaMedia(["audio": 1]) == .voice(seconds: nil))
        #expect(WAWebhook.gowaMedia(["document": ["filename": "a.pdf"]]) == .document(name: "a.pdf"))
        #expect(WAWebhook.gowaMedia(["sticker": 1]) == .sticker)
        #expect(WAWebhook.gowaMedia(["live_location": 1]) == .location)
        #expect(WAWebhook.gowaMedia(["contacts_array": 1]) == .contact)
        #expect(WAWebhook.gowaMedia(["poll": 1]) == .other)
    }

    @Test func parsesOpenWAMessages() {
        let event = WAWebhook.parse(kind: .openwa, body: StubURLProtocol.fixture("openwa_webhook_message.json"), me: "15550009999@c.us")
        guard case .message(let m)? = event else { Issue.record("no message"); return }
        #expect(m.chat == "120363000000000001@g.us")
        #expect(m.sender == "15550002222@c.us")
        #expect(m.senderName == "Bruno")
        #expect(m.media == .voice(seconds: nil))
        #expect(m.mentionsMe)
        #expect(m.date == Date(timeIntervalSince1970: 1792590000))
        let revoked = Data(#"{"event":"message.received","data":{"id":"x","chatId":"a@c.us","type":"revoked"}}"#.utf8)
        #expect(WAWebhook.parse(kind: .openwa, body: revoked) == .ignored)
        let sent = Data(#"{"event":"message.sent","data":{"id":"x","from":"a@c.us","body":"yo"}}"#.utf8)
        guard case .message(let mine)? = WAWebhook.parse(kind: .openwa, body: sent) else { Issue.record("no sent"); return }
        #expect(mine.fromMe)
        #expect(WAWebhook.openwaMedia("document", filename: "f") == .document(name: "f"))
        #expect(WAWebhook.openwaMedia("audio") == .audio(seconds: nil))
        #expect(WAWebhook.openwaMedia("poll") == .other)
    }
}

@Suite struct WhatsAppHTTPRequestTests {
    @Test func parsesAWholeRequest() {
        let raw = Data("POST /whatsapp HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Hub-Signature-256: sha256=ab\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .done(let request) = WAHTTPRequest.parse(raw) else { Issue.record("not parsed"); return }
        #expect(request.method == "POST")
        #expect(request.path == "/whatsapp")
        #expect(request.headers["x-hub-signature-256"] == "sha256=ab")
        #expect(request.body == Data("{}".utf8))
    }

    @Test func waitsForTheBodyAndRefusesTooMuch() {
        #expect(WAHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8)) == .incomplete)
        #expect(WAHTTPRequest.parse(Data("POST / HTTP/1.1\r\nHost: x".utf8)) == .incomplete)
        #expect(WAHTTPRequest.parse(Data(repeating: 0x41, count: 16_385)) == .invalid)
        #expect(WAHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 1000001\r\n\r\n".utf8)) == .invalid)
        #expect(WAHTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .invalid)
        #expect(WAHTTPRequest.parse(Data("NOPE\r\n\r\n".utf8)) == .invalid)
        let response = String(data: WAHTTPRequest.response(401, WAHTTPRequest.reason(401)), encoding: .utf8)
        #expect(response == "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    }
}

@Suite struct WhatsAppRESTParsingTests {
    @Test func gowaDevicesLoginAndChats() {
        let device = WAGOWA.device(StubURLProtocol.fixture("gowa_devices.json"))
        #expect(device?.id == "kobe")
        #expect(device?.status.link == .connected)
        let fresh = Data(#"{"results":[{"id":"kobe","state":"disconnected","jid":""}]}"#.utf8)
        #expect(WAGOWA.device(fresh)?.status.link == .needsQR)
        let offline = Data(#"{"results":[{"id":"kobe","state":"connecting","jid":"1@s.whatsapp.net"}]}"#.utf8)
        #expect(WAGOWA.device(offline)?.status.link == .connecting)
        #expect(WAGOWA.device(Data(#"{"results":[]}"#.utf8)) == nil)

        let qr = WAGOWA.qrPath(StubURLProtocol.fixture("gowa_login.json"))
        #expect(qr?.path == "/statics/qrcode/scan-qr-abc.png")
        #expect(qr?.seconds == 30)

        let chats = WAGOWA.chats(StubURLProtocol.fixture("gowa_chats.json"))
        // Stories and channels are in GOWA's list; they are not chats.
        #expect(chats.map(\.jid).count == 3)
        #expect(chats[1].name == "Acme team")
        #expect(WAGOWA.errorCode(Data(#"{"code":"ALREADY_LOGGED_IN"}"#.utf8)) == "ALREADY_LOGGED_IN")
    }

    @Test func gowaStoredMessages() {
        let messages = WAGOWA.messages(StubURLProtocol.fixture("gowa_chat_messages.json"), me: "15550009999@s.whatsapp.net")
        #expect(messages.map(\.id) == ["M3", "M2", "M1"])
        #expect(messages[0].media == .document(name: "menu.pdf"))
        #expect(messages[0].chatName == "Acme team")
        #expect(messages[1].fromMe)
        #expect(messages[2].mentionsMe)
        #expect(WAGOWA.gowaStoredMedia("call", filename: nil) == .other)
        #expect(WAGOWA.gowaStoredMedia("video_note", filename: nil) == .video)
    }

    @Test func launchArgumentsKeepKobesPortAndName() {
        #expect(WAGOWA.launchArguments(for: URL(string: "http://127.0.0.1:47840")!)
                == ["rest", "--host=127.0.0.1", "--port=47840", "--auto-download-media=false", "--os=Kobe"])
        #expect(WAGOWA.launchArguments(for: URL(string: "http://localhost")!)[2] == "--port=47840")
        #expect(WAGatewayKind.gowa.defaultURL == "http://127.0.0.1:47840")
        #expect(WAGatewayKind.openwa.defaultURL == "http://127.0.0.1:2785")
    }

    @Test func openwaSessionsAndMessages() {
        let sessions = (try? JSONSerialization.jsonObject(with: StubURLProtocol.fixture("openwa_sessions.json"))) as? [Any] ?? []
        #expect(sessions.compactMap(WAOpenWA.session).first?.id == "s-old")
        #expect(WAOpenWA.needsStart("disconnected") && !WAOpenWA.needsStart("ready"))
        #expect(WAOpenWA.status(("a", "ready", "1555")) == WAStatus(link: .connected, me: "1555"))
        #expect(WAOpenWA.status(("a", "qr_ready", "1555")) == WAStatus(link: .needsQR, me: nil))
        #expect(WAOpenWA.status(("a", "authenticating", nil)).link == .connecting)

        let messages = WAOpenWA.messages(StubURLProtocol.fixture("openwa_messages.json"), me: nil)
        #expect(messages.map(\.id) == ["W2", "W1"])
        #expect(messages[0].media == .image)
        #expect(messages[1].fromMe && messages[1].chatName == "Ana")
        #expect(messages[1].date == Date(timeIntervalSince1970: 1792590000))

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let qr = Data(#"{"qrCode":"data:image/png;base64,\#(png.base64EncodedString())"}"#.utf8)
        #expect(WAOpenWA.qrPNG(qr) == png)
        #expect(WAOpenWA.errorMessage(Data(#"{"message":["a","b"]}"#.utf8)) == "a, b")
        #expect(WAOpenWA.chatId("1555@s.whatsapp.net") == "1555@c.us")
        #expect(WAOpenWA.chatId("1@g.us") == "1@g.us")
    }
}

@Suite struct WhatsAppReleaseTests {
    @Test func picksThisMacsZipAndChecksum() throws {
        let release = try #require(WAGOWARelease.parse(StubURLProtocol.fixture("gowa_release.json")))
        #expect(release.version == "9.6.0")
        let arm = try #require(WAGOWARelease.pick(release.assets, arch: "arm64"))
        #expect(arm.zip.name == "whatsapp_9.6.0_darwin_arm64.zip")
        #expect(arm.checksums?.name == "checksums-macos.txt")
        #expect(WAGOWARelease.pick(release.assets, arch: "amd64")?.zip.name == "whatsapp_9.6.0_darwin_amd64.zip")
        #expect(WAGOWARelease.pick(release.assets, arch: "riscv") == nil)
        #expect(WAGOWARelease.binaryName(arch: "arm64") == "darwin-arm64")

        let hex = String(repeating: "a", count: 64)
        let sums = "\(String(repeating: "c", count: 64))  whatsapp_9.6.0_darwin_amd64.zip\n\(hex.uppercased())  whatsapp_9.6.0_darwin_arm64.zip\n"
        #expect(WAGOWARelease.expectedSHA256(for: arm.zip, checksums: sums) == hex)
        // No checksums file: GitHub's own digest.
        #expect(WAGOWARelease.expectedSHA256(for: arm.zip, checksums: nil) == String(repeating: "b", count: 64))
        let amd = try #require(WAGOWARelease.pick(release.assets, arch: "amd64"))
        #expect(WAGOWARelease.expectedSHA256(for: amd.zip, checksums: "garbage") == nil)
        #expect(WAGOWARelease.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func downloadsOnlyFromGitHub() {
        #expect(WAGOWARelease.allowedHost("github.com"))
        #expect(WAGOWARelease.allowedHost("API.github.com"))
        #expect(WAGOWARelease.allowedHost("objects.githubusercontent.com"))
        #expect(!WAGOWARelease.allowedHost("githubusercontent.com.evil.com"))
        #expect(!WAGOWARelease.allowedHost("evilgithub.com"))
        #expect(!WAGOWARelease.allowedHost(nil))
    }
}
