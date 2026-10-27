import Testing
@testable import KobeKit

@Test func pillsKeepOrderAndColours() {
    let items = Connections.items(status: [:])
    #expect(items.map(\.id) == ["stripe", "github", "vercel", "whatsapp"])
    #expect(items.map(\.tint) == [RGB(0x0570DE), RGB(0xF4505E), RGB(0x7C5CFF), RGB(0x25D366)])
    #expect(items.allSatisfy { $0.status == .notSetUp })
}

@Test func pillsTakeEachServiceStatus() {
    let items = Connections.items(status: ["github": .problem, "whatsapp": .connected], detail: ["github": "Pull requests"])
    #expect(items[1].status == .problem && items[1].detail == "Pull requests")
    #expect(items[3].status == .connected)
}
