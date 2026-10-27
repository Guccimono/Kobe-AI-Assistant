import Foundation
import Testing
@testable import KobeKit

private func json(_ request: URLRequest) -> [String: Any] {
    (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
}

private func query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

@Suite struct GOWAProviderTests {
    @Test func statusUsesTheLoggedInDeviceWithBasicAuth() async throws {
        let stub = StubURLProtocol.make { _ in .init(body: StubURLProtocol.fixture("gowa_devices.json")) }
        let provider = GOWAProvider(base: stub.base, basicAuth: "kobe:abc", session: stub.session)
        let status = try await provider.status()
        #expect(status.link == .connected)
        #expect(status.me == "33744998986:12@s.whatsapp.net")
        let request = try #require(StubURLProtocol.requests(stub.host).first)
        #expect(request.url?.path == "/devices")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("kobe:abc".utf8).base64EncodedString())
    }

    @Test func createsTheKobeDeviceWhenThereIsNone() async throws {
        let stub = StubURLProtocol.make { request in
            request.httpMethod == "POST" ? .init(body: Data(#"{"code":"SUCCESS"}"#.utf8)) : .init(body: Data(#"{"results":[]}"#.utf8))
        }
        let provider = GOWAProvider(base: stub.base, basicAuth: nil, session: stub.session)
        let status = try await provider.status()
        #expect(status.link == .needsQR)
        let post = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(post.httpMethod == "POST" && post.url?.path == "/devices")
        #expect(json(post)["device_id"] as? String == "kobe")
        #expect(post.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func mapsErrors() async {
        let unauthorized = StubURLProtocol.make { _ in .init(status: 401, body: Data("{}".utf8)) }
        await #expect(throws: WAError.unauthorized) {
            try await GOWAProvider(base: unauthorized.base, basicAuth: "a:b", session: unauthorized.session).status()
        }
        let notLogged = StubURLProtocol.make { _ in .init(status: 401, body: Data(#"{"code":"AUTHENTICATION_ERROR"}"#.utf8)) }
        await #expect(throws: WAError.notLoggedIn) {
            try await GOWAProvider(base: notLogged.base, basicAuth: nil, session: notLogged.session).status()
        }
        let refused = StubURLProtocol.make { _ in .init(status: 500, body: Data(#"{"code":"INTERNAL"}"#.utf8)) }
        await #expect(throws: WAError.refused("INTERNAL")) {
            try await GOWAProvider(base: refused.base, basicAuth: nil, session: refused.session).status()
        }
        let down = StubURLProtocol.make { _ in .init(error: URLError(.cannotConnectToHost)) }
        await #expect(throws: WAError.unreachable) {
            try await GOWAProvider(base: down.base, basicAuth: nil, session: down.session).status()
        }
    }

    @Test func qrComesFromTheGatewayItself() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2])
        let stub = StubURLProtocol.make { request in
            switch request.url?.path ?? "" {
            case "/devices": .init(body: Data(#"{"results":[{"id":"kobe","state":"disconnected"}]}"#.utf8))
            case "/devices/kobe/login": .init(body: StubURLProtocol.fixture("gowa_login.json"))
            case "/statics/qrcode/scan-qr-abc.png": .init(body: png)
            default: .init(status: 404)
            }
        }
        let provider = GOWAProvider(base: stub.base, basicAuth: nil, session: stub.session)
        let qr = try await provider.qrCode()
        #expect(qr?.png == png)
        #expect(qr?.seconds == 55)
        // The fixture's link names localhost:47840; the PNG is fetched from the configured gateway.
        #expect(StubURLProtocol.requests(stub.host).last?.url?.host == stub.host)
    }

    @Test func alreadyLoggedInHasNoQR() async throws {
        let stub = StubURLProtocol.make { request in
            request.url?.path == "/devices" ? .init(body: StubURLProtocol.fixture("gowa_devices.json"))
                : .init(status: 400, body: Data(#"{"code":"ALREADY_LOGGED_IN"}"#.utf8))
        }
        let qr = try await GOWAProvider(base: stub.base, basicAuth: nil, session: stub.session).qrCode()
        #expect(qr == nil)
    }

    @Test func registersTheSignedWebhook() async throws {
        let stub = StubURLProtocol.make { _ in .init(body: StubURLProtocol.fixture("gowa_devices.json")) }
        let provider = GOWAProvider(base: stub.base, basicAuth: nil, session: stub.session)
        try await provider.registerWebhook(url: "http://127.0.0.1:47841/whatsapp", secret: "abc")
        let patch = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(patch.httpMethod == "PATCH" && patch.url?.path == "/devices/kobe/webhook")
        #expect(json(patch)["webhook_url"] as? String == "http://127.0.0.1:47841/whatsapp")
        #expect(json(patch)["webhook_secret"] as? String == "abc")
        #expect(json(patch)["webhook_events"] as? String == "message")
    }

    @Test func pollsOnlyTheChatsThatMoved() async throws {
        let stub = StubURLProtocol.make { request in
            let path = request.url?.path ?? ""
            if path == "/devices" { return .init(body: StubURLProtocol.fixture("gowa_devices.json")) }
            if path == "/chats" { return .init(body: StubURLProtocol.fixture("gowa_chats.json")) }
            if path.hasPrefix("/chat/120363000000000000@g.us/messages") {
                return .init(body: StubURLProtocol.fixture("gowa_chat_messages.json"))
            }
            return .init(body: Data(#"{"results":{"data":[]}}"#.utf8))
        }
        let provider = GOWAProvider(base: stub.base, basicAuth: nil, session: stub.session)
        let since = WADate.rfc3339("2026-10-21T12:00:00Z")!
        let messages = try await provider.recentMessages(since: since, me: nil)
        #expect(messages.map(\.id) == ["M1", "M2", "M3"])   // oldest first
        let requests = StubURLProtocol.requests(stub.host)
        let chatCalls = requests.filter { $0.url?.path.hasPrefix("/chat/") == true }
        #expect(chatCalls.count == 2)   // the third chat moved before `since`
        #expect(chatCalls.allSatisfy { query($0, "device_id") == "kobe" && query($0, "limit") == "10" && query($0, "start_time") != nil })
        // Every chat, not the last 20: a week-old conversation is still in the list.
        #expect(query(requests.first { $0.url?.path == "/chats" }!, "limit") == "100")
        #expect(!chatCalls.contains { $0.url?.path.contains("broadcast") == true || $0.url?.path.contains("newsletter") == true })
    }

    @Test func sendsMarksReadAndNamesGroups() async throws {
        let stub = StubURLProtocol.make { request in
            switch request.url?.path ?? "" {
            case "/devices": .init(body: StubURLProtocol.fixture("gowa_devices.json"))
            case "/send/message": .init(body: Data(#"{"results":{"message_id":"NEW1"}}"#.utf8))
            case "/group/info": .init(body: Data(#"{"results":{"Name":"Team"}}"#.utf8))
            default: .init(body: Data(#"{"code":"SUCCESS"}"#.utf8))
            }
        }
        let provider = GOWAProvider(base: stub.base, basicAuth: nil, session: stub.session)
        let id = try await provider.send(text: "on my way", to: "15550001111@s.whatsapp.net")
        #expect(id == "NEW1")
        var sent = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(json(sent)["phone"] as? String == "15550001111@s.whatsapp.net")
        #expect(json(sent)["message"] as? String == "on my way")
        #expect(query(sent, "device_id") == "kobe")

        try await provider.markRead(chat: "15550001111@s.whatsapp.net", lastIncoming: "ABC")
        sent = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(sent.httpMethod == "POST" && sent.url?.path == "/message/ABC/read")
        let before = StubURLProtocol.requests(stub.host).count
        try await provider.markRead(chat: "x", lastIncoming: nil)
        #expect(StubURLProtocol.requests(stub.host).count == before)

        #expect(await provider.groupName("1@g.us") == "Team")
        #expect(await provider.groupName("1@s.whatsapp.net") == nil)
    }
}

@Suite struct OpenWAProviderTests {
    @Test func usesTheReadySessionWithTheAPIKey() async throws {
        let stub = StubURLProtocol.make { _ in .init(body: StubURLProtocol.fixture("openwa_sessions.json")) }
        let provider = OpenWAProvider(base: stub.base, apiKey: "owa_k1_x", session: stub.session)
        let status = try await provider.status()
        #expect(status == WAStatus(link: .connected, me: "15550009999"))
        let request = try #require(StubURLProtocol.requests(stub.host).first)
        #expect(request.url?.path == "/api/sessions")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "owa_k1_x")
    }

    @Test func createsAndStartsTheKobeSession() async throws {
        let stub = StubURLProtocol.make { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("GET", "/api/sessions"): .init(body: Data("[]".utf8))
            case ("POST", "/api/sessions"): .init(body: Data(#"{"id":"new","name":"kobe","status":"created"}"#.utf8))
            case ("POST", "/api/sessions/new/start"): .init(body: Data(#"{"id":"new","status":"qr_ready"}"#.utf8))
            default: .init(status: 404)
            }
        }
        let status = try await OpenWAProvider(base: stub.base, apiKey: nil, session: stub.session).status()
        #expect(status.link == .needsQR)
        let create = try #require(StubURLProtocol.requests(stub.host).first { $0.httpMethod == "POST" })
        #expect(json(create)["name"] as? String == "kobe")
    }

    @Test func mapsErrors() async {
        let forbidden = StubURLProtocol.make { _ in .init(status: 403, body: Data("{}".utf8)) }
        await #expect(throws: WAError.unauthorized) {
            try await OpenWAProvider(base: forbidden.base, apiKey: "x", session: forbidden.session).status()
        }
        let refused = StubURLProtocol.make { _ in .init(status: 422, body: Data(#"{"message":"bad"}"#.utf8)) }
        await #expect(throws: WAError.refused("bad")) {
            try await OpenWAProvider(base: refused.base, apiKey: "x", session: refused.session).status()
        }
    }

    @Test func webhookIsUpdatedWhenItExists() async throws {
        let stub = StubURLProtocol.make { request in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("GET", "/api/sessions"): .init(body: StubURLProtocol.fixture("openwa_sessions.json"))
            case ("GET", "/api/sessions/s-kobe/webhooks"):
                .init(body: Data(#"[{"id":"h1","url":"http://127.0.0.1:47841/whatsapp"}]"#.utf8))
            default: .init(body: Data("{}".utf8))
            }
        }
        let provider = OpenWAProvider(base: stub.base, apiKey: nil, session: stub.session)
        try await provider.registerWebhook(url: "http://127.0.0.1:47841/whatsapp", secret: "s")
        let put = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(put.httpMethod == "PUT" && put.url?.path == "/api/sessions/s-kobe/webhooks/h1")
        #expect(json(put)["events"] as? [String] == ["message.received", "message.sent"])
        #expect(json(put)["secret"] as? String == "s")
        try await provider.registerWebhook(url: "http://127.0.0.1:1/whatsapp", secret: "s")
        #expect(StubURLProtocol.requests(stub.host).last?.httpMethod == "POST")
    }

    @Test func messagesSendAndRead() async throws {
        let stub = StubURLProtocol.make { request in
            switch request.url?.path ?? "" {
            case "/api/sessions": .init(body: StubURLProtocol.fixture("openwa_sessions.json"))
            case "/api/sessions/s-kobe/messages": .init(body: StubURLProtocol.fixture("openwa_messages.json"))
            case "/api/sessions/s-kobe/messages/send-text": .init(body: Data(#"{"messageId":"OUT"}"#.utf8))
            default: .init(body: Data("{}".utf8))
            }
        }
        let provider = OpenWAProvider(base: stub.base, apiKey: nil, session: stub.session)
        let history = try await provider.messages(chat: "15550001111@s.whatsapp.net", limit: 10, me: nil)
        #expect(history.map(\.id) == ["W1", "W2"])
        let get = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(query(get, "chatId") == "15550001111@c.us")
        #expect(query(get, "inlineMedia") == "false")

        let recent = try await provider.recentMessages(since: Date(timeIntervalSince1970: 100), me: nil)
        #expect(recent.count == 2)
        #expect(query(StubURLProtocol.requests(stub.host).last!, "since") == "100000")

        #expect(try await provider.send(text: "hey", to: "15550001111@s.whatsapp.net") == "OUT")
        let send = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(json(send)["chatId"] as? String == "15550001111@c.us")
        #expect(json(send)["text"] as? String == "hey")

        try await provider.markRead(chat: "15550001111@s.whatsapp.net", lastIncoming: nil)
        let read = try #require(StubURLProtocol.requests(stub.host).last)
        #expect(read.url?.path == "/api/sessions/s-kobe/chats/read")
    }
}

@Suite struct WAHTTPTests {
    @Test func appendsPathsToTheBaseAndEncodesIds() throws {
        let http = WAHTTP(base: URL(string: "http://127.0.0.1:2785/gw/")!, headers: ["X-API-Key": "k"])
        let request = try http.request("POST", "/api/x", query: [URLQueryItem(name: "a", value: "b")], json: ["k": "v"])
        #expect(request.url?.absoluteString == "http://127.0.0.1:2785/gw/api/x?a=b")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.timeoutInterval == 10)
        #expect(WAHTTP.pathComponent("a b/c@g.us") == "a%20b%2Fc@g.us")
    }
}
