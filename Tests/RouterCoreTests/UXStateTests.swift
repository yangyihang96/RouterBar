import Testing
import Foundation
import Security
@testable import RouterCore

@Test func sdnVPNIndicesMatchFirmwareMapping() {
    #expect(SDNClientRoute("0") == .direct)
    #expect(SDNClientRoute("1") == .wireGuard(1))
    #expect(SDNClientRoute("5") == .wireGuard(5))
    #expect(SDNClientRoute("6") == .openVPN(1))
    #expect(SDNClientRoute("10") == .openVPN(5))
    #expect(SDNClientRoute("11") == nil)
    #expect(SDNClientRoute("01") == nil)
}
@Test func keychainOutcomesRemainDistinct() {
    #expect(CredentialAccessState.from(status: errSecItemNotFound) == .notFound)
    #expect(CredentialAccessState.from(status: errSecInteractionNotAllowed) == .interactionRequired)
    #expect(CredentialAccessState.from(status: errSecUserCanceled) == .canceled)
    #expect(CredentialAccessState.from(status: errSecAuthFailed) == .interactionRequired)
    #expect(CredentialAccessState.from(status: -999) == .failed(-999))
}
@Test func lateKeychainResultCannotCompleteCanceledOrSupersededRead() {
    var flow = CredentialAccessFlow()
    let first = flow.begin(.reading(.now)); flow.cancel()
    let canceledResult = flow.finish(first, state: .idle)
    #expect(!canceledResult); #expect(flow.state == .canceled)
    let second = flow.begin(.authorizing(.now))
    let staleResult = flow.finish(first, state: .notFound)
    #expect(!staleResult); #expect(flow.state.isWaiting)
    let currentResult = flow.finish(second, state: .interactionRequired)
    #expect(currentResult)
    #expect(!flow.state.isWaiting)
}
