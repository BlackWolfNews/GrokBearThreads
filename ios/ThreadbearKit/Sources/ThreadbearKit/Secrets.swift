import CryptoKit
import Foundation
import Security

// The phone's half of a secret card (docs/protocol.md, "Secrets"): the
// value is sealed here to the runner's X25519 key, so the Convex mirror in
// between only ever carries ciphertext. Nothing in this file logs, keeps or
// returns the value in the clear.

/// A secret sealed to a runner's key: what `phone:secret` takes as `sealed`.
/// All three are standard base64, padded.
public struct SealedSecret: Sendable, Hashable {
    /// The phone's ephemeral X25519 public key, raw.
    public var epk: String
    /// The 12-byte AES-GCM nonce.
    public var nonce: String
    /// The ciphertext, then the 16-byte tag.
    public var box: String

    public init(epk: String, nonce: String, box: String) {
        self.epk = epk
        self.nonce = nonce
        self.box = box
    }
}

/// What the phone sends for a secret card.
public enum SecretAnswer: Sendable, Hashable {
    case sealed(SealedSecret)
    case decline
}

public enum SecretSealError: Error, Equatable {
    /// The card's `key` isn't base64 of a 32-byte X25519 public key.
    case badKey
}

/// The seal (docs/protocol.md, "The seal"): an ephemeral X25519 key agrees a
/// shared secret with the runner's, HKDF-SHA256 (salt epk ‖ key, info
/// "threadbear secret v1 <approvalId>") makes a 32-byte key, and
/// AES-256-GCM seals the UTF-8 value with a random 12-byte nonce. The
/// approval id in the info means a sealed answer can't be replayed onto
/// another card. Must match runner/src/secrets.ts byte for byte.
public enum SecretSeal {
    public static func seal(
        _ value: String, toKey runnerKey: String, approvalId: String,
        ephemeral: Curve25519.KeyAgreement.PrivateKey = .init(),
        nonce nonceBytes: Data? = nil
    ) throws -> SealedSecret {
        guard let keyData = Data(base64Encoded: runnerKey), keyData.count == 32,
              let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData) else {
            throw SecretSealError.badKey
        }
        let epk = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: epk + recipient.rawRepresentation,
            sharedInfo: Data("threadbear secret v1 \(approvalId)".utf8),
            outputByteCount: 32)
        let nonce = try nonceBytes.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(Data(value.utf8), using: key, nonce: nonce)
        return SealedSecret(
            epk: epk.base64EncodedString(),
            nonce: Data(nonce).base64EncodedString(),
            box: (sealed.ciphertext + sealed.tag).base64EncodedString())
    }

    /// Whether a card's `key` is one the phone could seal to.
    public static func isUsableKey(_ key: String) -> Bool {
        guard let data = Data(base64Encoded: key), data.count == 32 else { return false }
        return (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)) != nil
    }
}

// MARK: Trusting the key

/// Where the first key seen for each runner is kept.
public protocol RunnerKeyStore: Sendable {
    func key(for runnerId: String) -> String?
    func save(_ key: String, for runnerId: String)
}

/// Trust on first use (docs/protocol.md, "Trusting the key"): the first key
/// a runner's card carries is kept, and a card with any other key later is
/// refused, rather than sealing to a key the backend could have swapped in.
public enum RunnerKeyPins {
    public enum Trust: Sendable, Equatable {
        /// The kept key, or the first one seen (now kept).
        case trusted
        /// Not the key this phone kept for that runner.
        case changed
    }

    public static func check(_ key: String, runnerId: String, in store: any RunnerKeyStore) -> Trust {
        if let kept = store.key(for: runnerId) {
            // Compared as bytes, so a re-encoding of the same key isn't a change.
            return Data(base64Encoded: kept) == Data(base64Encoded: key) ? .trusted : .changed
        }
        store.save(key, for: runnerId)
        return .trusted
    }
}

/// For tests and the demo, which shouldn't leave anything in the keychain.
public final class MemoryRunnerKeyStore: RunnerKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    public init(_ keys: [String: String] = [:]) { self.keys = keys }
    public func key(for runnerId: String) -> String? { lock.withLock { keys[runnerId] } }
    public func save(_ key: String, for runnerId: String) { lock.withLock { keys[runnerId] = key } }
}

/// The real store: one keychain item per runner, under the paired
/// deployment, this device only. Only the app reads it (the notification
/// extension never shows a secret card), so there's no access group.
/// Unpairing clears them all (`clearAll`), which is how a runner's key is
/// trusted again after it's been deleted on purpose.
public struct KeychainRunnerKeyStore: RunnerKeyStore {
    static let service = "com.mikecann.threadbear.runnerKey"
    /// The deployment's host, so the same runner id on two backends is two keys.
    let scope: String

    public init(scope: String) { self.scope = scope }

    private func base(_ runnerId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "\(scope)/\(runnerId)"]
    }

    public func key(for runnerId: String) -> String? {
        var query = base(runnerId)
        query[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String, for runnerId: String) {
        var item = base(runnerId)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Add only: a key already kept is never overwritten from here.
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func clearAll() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }
}
