import Foundation
import Testing
@testable import KobeKit

struct HandoverTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func shimWritesWhenNoFile() {
        #expect(Handover.shimMayWrite(existing: nil, id: .stripe, status: .ok, now: now))
        #expect(Handover.owner(existing: nil, id: .stripe, now: now) == .app)
    }

    @Test func shimYieldsToFreshAgentFile() {
        let fresh = (source: SnapshotSource.agent, updatedAt: now - 60)
        #expect(!Handover.shimMayWrite(existing: fresh, id: .stripe, status: .ok, now: now))
        // Its own earlier file never stops it.
        #expect(Handover.shimMayWrite(existing: (source: .app, updatedAt: now - 60), id: .stripe, status: .ok, now: now))
    }

    @Test func shimTakesOverStaleAgentFile() {
        let stale = (source: SnapshotSource.agent, updatedAt: now - (3 * 600 + 1))
        #expect(Handover.shimMayWrite(existing: stale, id: .stripe, status: .ok, now: now))
        #expect(Handover.owner(existing: stale, id: .stripe, now: now) == .app)
        let edge = (source: SnapshotSource.agent, updatedAt: now - 3 * 600)
        #expect(!Handover.shimMayWrite(existing: edge, id: .stripe, status: .ok, now: now))
    }

    @Test func shimNeverBlanksAnAgentFileWithNotSetUp() {
        // The app key was removed once Kobe Agent took over; a stale agent file keeps its last numbers.
        let stale = (source: SnapshotSource.agent, updatedAt: now - (3 * 600 + 1))
        #expect(!Handover.shimMayWrite(existing: stale, id: .stripe, status: .notSetUp, now: now))
        #expect(Handover.shimMayWrite(existing: stale, id: .stripe, status: .failed, now: now))
        #expect(Handover.shimMayWrite(existing: (source: .app, updatedAt: now - 60), id: .stripe, status: .notSetUp, now: now))
        #expect(Handover.shimMayWrite(existing: nil, id: .stripe, status: .notSetUp, now: now))
    }

    @Test func ownerIsAgentWhileFresh() {
        #expect(Handover.owner(existing: (source: .agent, updatedAt: now - 10), id: .google, now: now) == .agent)
        #expect(Handover.owner(existing: (source: .app, updatedAt: now - 10), id: .google, now: now) == .app)
    }

    @Test func headerReadsSourceAndDateOnly() {
        let json = #"{"id":"stripe","version":1,"updated_at":"2026-10-23T14:28:10Z","status":"ok","source":"agent","data":{"x":[1]}}"#
        let header = SnapshotDecode.header(Data(json.utf8))
        #expect(header?.source == .agent)
        #expect(header?.updatedAt == ISO8601DateFormatter().date(from: "2026-10-23T14:28:10Z"))
        #expect(SnapshotDecode.header(Data("{\"id\":".utf8)) == nil)
        let noSource = #"{"id":"stripe","version":1,"updated_at":"2026-10-23T14:28:10Z"}"#
        #expect(SnapshotDecode.header(Data(noSource.utf8))?.source == .app)
    }
}
