import Foundation
import CommonCrypto
import GrentonModel

@nonexhaustive

public enum CryptoError: Error, Sendable, Equatable {
    case invalidKeyMaterial
    case encryptFailed
}

/// Datagram cipher boundary (spec §7.2). A protocol so tests can substitute
/// an identity cipher and future ports can swap the AES backend.
///
/// The two directions fail differently by design (spec §8): a failed
/// outbound encryption is a request-path error the caller must see, so it
/// throws; a failed inbound decryption is the silent-drop boundary of the
/// receive path (spec §5.1), so it returns `nil` and the session logs one
/// generic warning without distinguishing the failure kind.
public protocol GrentonCipher: Sendable {
    /// PKCS#7-pads and encrypts. Throws `CryptoError.encryptFailed` on an
    /// internal failure.
    func encrypt(_ plaintext: Data) throws -> Data
    /// Decrypts and strictly validates/strips PKCS#7 padding (spec §5.1).
    /// `nil` for any malformed input — the receive path drops such datagrams.
    func decrypt(_ ciphertext: Data) -> Data?
}

/// AES-CBC with the interface's static key and IV (spec §5.1).
///
/// Padding is applied and validated manually around a raw (padding-less)
/// CBC pass, so the strict all-bytes-equal check of the spec holds exactly —
/// CommonCrypto's own PKCS7 handling is not relied upon for validation.
///
/// The static IV makes encryption deterministic; that is a property of the
/// Grenton protocol (and what makes cross-port golden vectors possible).
/// The scheme provides no integrity or authenticity.
///
/// Memory hygiene: key, IV, and transient plaintext buffers live in ordinary
/// copy-on-write `Data` storage — Foundation does not guarantee zeroization
/// on release, and this implementation makes no secure-erasure claim (the
/// reference implementation makes none either). Callers must never log key
/// material or plaintext.
public struct AesCbcCipher: GrentonCipher {
    private let key: Data
    private let iv: Data

    public init(keyBase64: String, ivBase64: String) throws {
        guard let key = Data(base64Encoded: keyBase64),
              [kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count)
        else { throw CryptoError.invalidKeyMaterial }
        guard let iv = Data(base64Encoded: ivBase64),
              iv.count == kCCBlockSizeAES128
        else { throw CryptoError.invalidKeyMaterial }
        self.key = key
        self.iv = iv
    }

    public init(encryption: EncryptionDTO) throws {
        try self.init(keyBase64: encryption.key, ivBase64: encryption.iv)
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let blockSize = kCCBlockSizeAES128
        let paddingLength = blockSize - (plaintext.count % blockSize)
        var padded = plaintext
        padded.append(contentsOf: [UInt8](repeating: UInt8(paddingLength), count: paddingLength))
        guard let encrypted = rawCrypt(CCOperation(kCCEncrypt), input: padded) else {
            throw CryptoError.encryptFailed
        }
        return encrypted
    }

    public func decrypt(_ ciphertext: Data) -> Data? {
        let blockSize = kCCBlockSizeAES128
        guard !ciphertext.isEmpty, ciphertext.count % blockSize == 0 else { return nil }
        guard var plaintext = rawCrypt(CCOperation(kCCDecrypt), input: ciphertext) else { return nil }

        // Strict PKCS#7 validation (spec §5.1): length 1...16 and every
        // padding byte equal to the length.
        guard let last = plaintext.last else { return nil }
        let paddingLength = Int(last)
        guard (1...blockSize).contains(paddingLength),
              plaintext.count >= paddingLength,
              plaintext.suffix(paddingLength).allSatisfy({ $0 == last })
        else { return nil }

        plaintext.removeLast(paddingLength)
        return plaintext
    }

    /// One-shot CBC pass without any padding option; input must already be
    /// block-aligned.
    private func rawCrypt(_ operation: CCOperation, input: Data) -> Data? {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputPtr in
            input.withUnsafeBytes { inputPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            inputPtr.baseAddress, input.count,
                            outputPtr.baseAddress, outputPtr.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return output
    }
}
