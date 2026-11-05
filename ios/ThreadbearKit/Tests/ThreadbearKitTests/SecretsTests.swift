import CryptoKit
import Foundation
import Testing
@testable import ThreadbearKit

@Suite struct SecretsTests {
    // The vector from the runner's side (runner/src/secrets.ts), so the two
    // seal and open the same bytes.
    static let recipientPrivate = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
    static let recipientPublic = "pOCSkrZRwni5dyxWn1+puxPZBrRqtoyd+dwrRAn4ogk="
    static let ephemeralPrivate = "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="

    @Test func sealMatchesTheRunnersVector() throws {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: Self.ephemeralPrivate)!)
        let sealed = try SecretSeal.seal("hunter2 \u{2713}", toKey: Self.recipientPublic, approvalId: "approval-123",
                                         ephemeral: ephemeral, nonce: Data(base64Encoded: "AwMDAwMDAwMDAwMD")!)
        #expect(sealed.epk == "zo060cy2M+x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk=")
        #expect(sealed.nonce == "AwMDAwMDAwMDAwMD")
        #expect(sealed.box == "818iYL0/xbv1amlCprX8NVHr59l6QxFyCAWu")
    }

    @Test func theRunnersKeyOpensIt() throws {
        let sealed = try SecretSeal.seal("s3cret", toKey: Self.recipientPublic, approvalId: "a1")
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(base64Encoded: Self.recipientPrivate)!)
        #expect(recipient.publicKey.rawRepresentation.base64EncodedString() == Self.recipientPublic)
        let epk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(base64Encoded: sealed.epk)!)
        func open(approvalId: String) throws -> String {
            let key = try recipient.sharedSecretFromKeyAgreement(with: epk).hkdfDerivedSymmetricKey(
                using: SHA256.self, salt: epk.rawRepresentation + recipient.publicKey.rawRepresentation,
                sharedInfo: Data("threadbear secret v1 \(approvalId)".utf8), outputByteCount: 32)
            let box = Data(base64Encoded: sealed.box)!
            let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(base64Encoded: sealed.nonce)!),
                                                  ciphertext: box.dropLast(16), tag: box.suffix(16))
            return String(decoding: try AES.GCM.open(sealedBox, using: key), as: UTF8.self)
        }
        #expect(try open(approvalId: "a1") == "s3cret")
        // Bound to its card: another approval id can't open it.
        #expect(throws: (any Error).self) { try open(approvalId: "a2") }
    }

    @Test func eachSealIsFresh() throws {
        let a = try SecretSeal.seal("same", toKey: Self.recipientPublic, approvalId: "a1")
        let b = try SecretSeal.seal("same", toKey: Self.recipientPublic, approvalId: "a1")
        #expect(a.epk != b.epk)
        #expect(a.nonce != b.nonce)
        #expect(Data(base64Encoded: a.nonce)?.count == 12)
    }

    @Test func aBadKeyIsRefused() {
        #expect(throws: SecretSealError.badKey) { try SecretSeal.seal("x", toKey: "not base64!", approvalId: "a") }
        #expect(throws: SecretSealError.badKey) { try SecretSeal.seal("x", toKey: Data(count: 16).base64EncodedString(), approvalId: "a") }
        #expect(!SecretSeal.isUsableKey("AAAA"))
        #expect(SecretSeal.isUsableKey(Self.recipientPublic))
    }

    @Test func theFirstKeyIsKeptAndAChangeIsRefused() {
        let store = MemoryRunnerKeyStore()
        let other = Data(repeating: 9, count: 32).base64EncodedString()
        #expect(RunnerKeyPins.check(Self.recipientPublic, runnerId: "mac", threadId: "t1", in: store) == .trusted)
        #expect(store.key(for: "mac") == Self.recipientPublic)
        #expect(RunnerKeyPins.check(Self.recipientPublic, runnerId: "mac", threadId: "t1", in: store) == .trusted)
        #expect(RunnerKeyPins.check(other, runnerId: "mac", threadId: "t1", in: store) == .changed)
        // The refused key never replaces the kept one.
        #expect(store.key(for: "mac") == Self.recipientPublic)
        // Each runner has its own.
        #expect(RunnerKeyPins.check(other, runnerId: "bruce", threadId: "t2", in: store) == .trusted)
    }

    /// The backend moving a thread the phone knows onto a fresh runner id
    /// with its own key: refused, and nothing about the new runner is kept.
    @Test func aThreadMovedToAnotherRunnerIsRefused() {
        let store = MemoryRunnerKeyStore()
        let evil = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(RunnerKeyPins.check(Self.recipientPublic, runnerId: "mac", threadId: "t1", in: store) == .trusted)
        #expect(RunnerKeyPins.check(evil, runnerId: "fresh", threadId: "t1", in: store) == .moved)
        #expect(store.key(for: "fresh") == nil)
        #expect(store.runner(forThread: "t1") == "mac")
        // Back on its own runner, it's fine again.
        #expect(RunnerKeyPins.check(Self.recipientPublic, runnerId: "mac", threadId: "t1", in: store) == .trusted)
    }

    /// A thread seen in a list is pinned then, so a move is caught even on
    /// its first secret card.
    @Test func threadsSeenInAListArePinned() {
        let store = MemoryRunnerKeyStore()
        RunnerKeyPins.noteThreads([("t1", "mac"), ("t2", "bruce"), ("t3", "")], in: store)
        #expect(store.runner(forThread: "t1") == "mac")
        #expect(store.runner(forThread: "t3") == nil)
        let evil = Data(repeating: 7, count: 32).base64EncodedString()
        #expect(RunnerKeyPins.check(evil, runnerId: "fresh", threadId: "t1", in: store) == .moved)
        // A list that later says otherwise doesn't move the pin.
        RunnerKeyPins.noteThreads([("t1", "fresh")], in: store)
        #expect(store.runner(forThread: "t1") == "mac")
        #expect(RunnerKeyPins.check(Self.recipientPublic, runnerId: "bruce", threadId: "t2", in: store) == .trusted)
    }

    /// Normal use needs no prompts: new threads on known Macs, a new Mac,
    /// a fresh install with nothing kept.
    @Test func newThreadsAndNewMacsAreTrustedOnFirstUse() {
        let store = MemoryRunnerKeyStore()
        let bruceKey = Data(repeating: 5, count: 32).base64EncodedString()
        #expect(RunnerKeyPins.check(Self.recipientPublic, runnerId: "mac", threadId: "t1", in: store) == .trusted)
        #expect(RunnerKeyPins.check(Self.recipientPublic, runnerId: "mac", threadId: "t2", in: store) == .trusted)
        #expect(RunnerKeyPins.check(bruceKey, runnerId: "bruce", threadId: "t3", in: store) == .trusted)
        #expect(store.runner(forThread: "t3") == "bruce")
    }

    @Test func secretCardsDecode() throws {
        let json = #"{"approvalId":"s1","kind":"secret","label":"Mac administrator password","reason":"To install it","key":"\#(Self.recipientPublic)"}"#
        let pending = try JSONDecoder().decode(PendingApproval.self, from: Data(json.utf8))
        #expect(pending == .secret(id: "s1", label: "Mac administrator password", reason: "To install it", placeholder: nil, key: Self.recipientPublic))
        // And back, as the fake and the tests make rows.
        #expect(try JSONDecoder().decode(PendingApproval.self, from: JSONEncoder().encode(pending)) == pending)

        let noKey = try JSONDecoder().decode(PendingApproval.self, from: Data(#"{"approvalId":"s2","kind":"secret","label":"x","reason":"y"}"#.utf8))
        #expect(noKey == .other(id: "s2", kind: "secret"))
        // A kind from a newer runner waits for the Mac rather than showing Allow and Deny.
        let newer = try JSONDecoder().decode(PendingApproval.self, from: Data(#"{"approvalId":"n","kind":"somethingNew"}"#.utf8))
        #expect(newer == .other(id: "n", kind: "somethingNew"))
        #expect(newer.id == "n")
    }

    @Test func theFakeTakesASecret() async throws {
        let backend = FakeBackend(turnDelay: .zero, secret: true)
        var stream = backend.thread("secret").makeAsyncIterator()
        guard case .secret? = try await stream.next()??.thread.pendingApproval else {
            Issue.record("no secret card")
            return
        }
        let sealed = try SecretSeal.seal("x", toKey: FakeBackend.sampleSecretKey, approvalId: "sec1")
        _ = try await backend.secret(threadId: "secret", approvalId: "sec1", answer: .sealed(sealed))
        #expect(try await stream.next()??.thread.pendingApproval == nil)
    }
}
