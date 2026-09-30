import Testing
import Foundation
@testable import GrentonRuntime

/// Golden-vector conformance (spec §9.1) — the static IV makes AES-CBC
/// deterministic, so these exact bytes bind every port of the library.
@Suite struct CipherTests {

    struct VectorFile: Decodable {
        struct Vector: Decodable {
            let name: String
            let plaintext: String
            let ciphertextHex: String
        }
        struct InvalidVector: Decodable {
            let name: String
            let ciphertextHex: String
        }
        let keyBase64: String
        let ivBase64: String
        let vectors: [Vector]
        let invalidPadding: [InvalidVector]
    }

    func loadVectors() throws -> (cipher: AesCbcCipher, file: VectorFile) {
        let url = try #require(Bundle.module.url(
            forResource: "aes_vectors", withExtension: "json", subdirectory: "Fixtures"))
        let file = try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
        let cipher = try AesCbcCipher(keyBase64: file.keyBase64, ivBase64: file.ivBase64)
        return (cipher, file)
    }

    func hexData(_ hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test func encryptMatchesGoldenVectors() throws {
        let (cipher, file) = try loadVectors()
        for vector in file.vectors {
            let encrypted = try cipher.encrypt(Data(vector.plaintext.utf8))
            #expect(encrypted == hexData(vector.ciphertextHex), "vector: \(vector.name)")
        }
    }

    @Test func decryptMatchesGoldenVectors() throws {
        let (cipher, file) = try loadVectors()
        for vector in file.vectors {
            let decrypted = try #require(cipher.decrypt(hexData(vector.ciphertextHex)),
                                         "decrypt failed for \(vector.name)")
            #expect(String(data: decrypted, encoding: .utf8) == vector.plaintext,
                    "vector: \(vector.name)")
        }
    }

    @Test func rejectsInvalidPadding() throws {
        let (cipher, file) = try loadVectors()
        for vector in file.invalidPadding {
            #expect(cipher.decrypt(hexData(vector.ciphertextHex)) == nil,
                    "should reject: \(vector.name)")
        }
    }

    @Test(arguments: [0, 1, 15, 16, 17, 31, 32, 1000])
    func roundTripsArbitraryLengths(length: Int) throws {
        let (cipher, _) = try loadVectors()
        let plaintext = Data((0..<length).map { UInt8($0 % 251) })
        let encrypted = try cipher.encrypt(plaintext)
        // PKCS7 always pads: ciphertext is the next full block boundary.
        #expect(encrypted.count == (length / 16 + 1) * 16)
        #expect(cipher.decrypt(encrypted) == plaintext)
    }

    @Test func rejectsMalformedCiphertextShapes() throws {
        let (cipher, _) = try loadVectors()
        #expect(cipher.decrypt(Data()) == nil)
        #expect(cipher.decrypt(Data(repeating: 0xAB, count: 15)) == nil)
        #expect(cipher.decrypt(Data(repeating: 0xAB, count: 17)) == nil)
    }

    @Test(arguments: [
        ("not-base64!!", "EBESExQVFhcYGRobHB0eHw=="),   // bad key encoding
        ("AAECAwQFBgcICQoLDA0O", "EBESExQVFhcYGRobHB0eHw=="),   // 15-byte key
        ("AAECAwQFBgcICQoLDA0ODw==", "EBESExQVFhcYGRob"),        // 12-byte IV
        ("AAECAwQFBgcICQoLDA0ODw==", "bad!"),
    ])
    func rejectsInvalidKeyMaterial(keyBase64: String, ivBase64: String) {
        #expect(throws: CryptoError.invalidKeyMaterial) {
            _ = try AesCbcCipher(keyBase64: keyBase64, ivBase64: ivBase64)
        }
    }

    @Test(arguments: [24, 32])
    func roundTripsWithWiderKeySizes(keyLength: Int) throws {
        let iv = "EBESExQVFhcYGRobHB0eHw=="
        let key = Data((0..<keyLength).map { UInt8($0) }).base64EncodedString()
        let cipher = try AesCbcCipher(keyBase64: key, ivBase64: iv)
        let plaintext = Data("req::aabbccdd:checkAlive()".utf8)
        let encrypted = try cipher.encrypt(plaintext)
        #expect(cipher.decrypt(encrypted) == plaintext)
    }

    @Test(arguments: [0, 8, 15, 17, 33, 64])
    func rejectsInvalidKeyLengths(keyLength: Int) {
        let iv = "EBESExQVFhcYGRobHB0eHw=="
        let key = Data(repeating: 0x01, count: keyLength).base64EncodedString()
        #expect(throws: CryptoError.invalidKeyMaterial) {
            _ = try AesCbcCipher(keyBase64: key, ivBase64: iv)
        }
    }
}
