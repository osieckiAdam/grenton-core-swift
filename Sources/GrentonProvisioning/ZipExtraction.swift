import Foundation
import ZIPFoundation

// One bounded extraction for both archives the module reads (spec §4.3
// pt 4, §4.5.1 pt 3): the stream is held to the size the entry header
// declares and to the caller's limit WHILE it decompresses, so a header
// that lies about its size cannot grow the buffer past the limit, and an
// entry whose final size differs from its declaration is rejected.
extension Archive {
    func extractBounded(_ entry: Entry, name: String, limit: Int) throws -> Data {
        let declared = Int(entry.uncompressedSize)
        guard declared <= limit else {
            throw ProvisioningError.invalidData("\(name) larger than \(limit) bytes")
        }
        var data = Data()
        data.reserveCapacity(declared)
        do {
            let checksum = try extract(entry, bufferSize: 64 * 1024) { chunk in
                guard data.count + chunk.count <= declared else {
                    throw ProvisioningError.invalidData("\(name): longer than its declared size")
                }
                data.append(chunk)
            }
            // The consumer overload computes but does not verify the CRC.
            guard checksum == entry.checksum else {
                throw ProvisioningError.invalidData("\(name): checksum mismatch")
            }
        } catch let error as ProvisioningError {
            throw error
        } catch {
            throw ProvisioningError.invalidData("\(name): extraction failed")
        }
        guard data.count == declared else {
            throw ProvisioningError.invalidData("\(name): shorter than its declared size")
        }
        return data
    }
}
