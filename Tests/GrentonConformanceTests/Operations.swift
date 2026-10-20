import Foundation
import GrentonModel
import GrentonRuntime
import GrentonDevices
@testable import GrentonProvisioning

/// Operation handlers (`spec/conformance.md` §4). Each one decodes the case
/// input, calls the production API and projects the observation to JSON —
/// no protocol logic lives here.

enum Operations {
    typealias Handler = @Sendable (JSON) throws -> JSON

    static let registry: [String: Handler] = [
        "crypto.encrypt": { input in
            let cipher = try AesCbcCipher(keyBase64: try input.string("keyBase64"),
                                          ivBase64: try input.string("ivBase64"))
            let ciphertext = try cipher.encrypt(try hex(input.string("plaintextHex")))
            return ok(["ciphertextHex": .string(hexString(ciphertext))])
        },
        "crypto.decrypt": { input in
            let cipher = try AesCbcCipher(keyBase64: try input.string("keyBase64"),
                                          ivBase64: try input.string("ivBase64"))
            guard let plaintext = cipher.decrypt(try hex(input.string("ciphertextHex"))) else { return reject }
            return ok(["plaintextHex": .string(hexString(plaintext))])
        },
        "wire.request": { input in
            ok(["frame": .string(WireFrame.request(msgId: try input.string("msgId"),
                                                   payload: try input.string("payload")))])
        },
        "wire.response": { input in
            guard let response = WireFrame.parseResponse(try input.string("frame")) else { return reject }
            return ok([
                "cluIp": .string(response.cluIp),
                "msgId": .string(response.msgId),
                "payload": .string(response.payload),
                "isNotification": .bool(response.isNotification),
            ])
        },
        "payload.register": { input in
            guard let sessionId = input["sessionId"]?.intValue, let keys = input["keys"]?.arrayValue else {
                throw SuiteError("payload.register: bad input")
            }
            let refs: [ValueRef] = try keys.map { key in
                switch key["type"]?.stringValue {
                case "variable":
                    return .variable(cluId: "CLU", name: try key.string("name"))
                case "attribute":
                    return .attribute(cluId: "CLU", objectName: try key.string("objectName"),
                                      index: try key.string("index"))
                default:
                    throw SuiteError("payload.register: unknown key type in \(key)")
                }
            }
            return ok(["payload": .string(try Payloads.clientRegister(sessionId: sessionId, keys: refs))])
        },
        "payload.action": { input in
            guard let actionJSON = input["action"] else { throw SuiteError("payload.action: no action") }
            // The ActionRef is parsed exactly as it would be from data.json;
            // a parse failure (§3.6) is the case's `reject`.
            guard let dto = try? JSONDecoder().decode(ActionRefDTO.self, from: actionJSON.data()),
                  let action = try? ActionRef(dto: dto) else { return reject }
            return ok(["payload": .string(try Payloads.action(action))])
        },
        "payload.fetch": { input in
            guard let keys = input["keys"]?.arrayValue else { throw SuiteError("payload.fetch: bad input") }
            let refs: [ValueRef] = try keys.map { key in
                switch key["type"]?.stringValue {
                case "variable":
                    return .variable(cluId: "CLU", name: try key.string("name"))
                case "attribute":
                    return .attribute(cluId: "CLU", objectName: try key.string("objectName"),
                                      index: try key.string("index"))
                default:
                    throw SuiteError("payload.fetch: unknown key type in \(key)")
                }
            }
            return ok(["payload": .string(try Payloads.fetchValues(keys: refs))])
        },
        "payload.values": { input in
            guard let values = Payloads.parseValues(try input.string("payload")) else { return reject }
            return ok(["values": .array(values.map(tagged))])
        },
        "payload.report": { input in
            guard let report = Payloads.parseClientReport(try input.string("payload")) else { return reject }
            return ok([
                "sessionId": .number(Double(report.sessionId)),
                "values": .array(report.values.map(tagged)),
            ])
        },
        "value.cast": { input in
            ok(["value": tagged(GrentonValue(wireString: try input.string("text")))])
        },
        "provisioning.url": { input in
            let port = input["port"]?.intValue ?? ProvisioningClient.defaultPort
            let client = ProvisioningClient(host: try input.string("host"), port: port)
            return ok(["url": .string(try client.endpointURL(pin: try input.string("pin")).absoluteString)])
        },
        "coercion.boolFromOnOff": { input in
            ok(["result": optionalBool(boolFromOnOff(try untagged(input["value"])))])
        },
        "coercion.truthy": { input in
            ok(["result": optionalBool(truthy(try untagged(input["value"])))])
        },
        "mapping.interface": { input in
            let data = try Data(contentsOf: ConformanceSuite.conformanceRoot
                .appendingPathComponent(try input.string("fixture")))
            // An interface that fails decoding as a whole is the case's `reject`.
            guard let interface = try? MobileInterfaceDTO.decode(from: data) else { return reject }
            return .object(["outcome": .string("ok"), "value": MappingProjection.interface(interface)])
        },
        "provisioning.omp": { input in
            let data = try Data(contentsOf: ConformanceSuite.conformanceRoot
                .appendingPathComponent(try input.string("fixture")))
            let project = try ProjectFile(data: data)
            let interface = try project.interface(id: input["interfaceId"]?.stringValue)
            return ok([
                "interfaces": .array(project.interfaces.map {
                    .object(["id": .string($0.id), "name": .string($0.name)])
                }),
                "interface": ProjectProjection.root(interface),
                "mapping": MappingProjection.interface(interface),
            ])
        },
        "number.format": { input in
            guard case .double(let value) = try untagged(input["value"]),
                  let precision = input["precision"]?.intValue else {
                throw SuiteError("number.format: bad input")
            }
            return ok(["text": .string(formatDeviceNumber(value, precision: precision))])
        },
    ]

    /// Runs one case and returns its observed `expect`-shaped outcome.
    /// Errors from the production API become `error` outcomes; a missing
    /// handler or undecodable input is a runner failure (thrown).
    static func run(_ testCase: ConformanceCase) async throws -> JSON {
        if testCase.operation == "session.scenario" {
            // Stateful and asynchronous (conformance.md §4b), so it bypasses
            // the synchronous registry.
            guard let steps = testCase.input["steps"]?.arrayValue else { throw SuiteError("session.scenario: no steps") }
            let observed = try await SessionScenario(input: testCase.input).run(steps)
            return .object(["outcome": .string("ok"), "value": observed])
        }
        guard let handler = registry[testCase.operation] else {
            throw SuiteError("no handler for operation \(testCase.operation)")
        }
        do {
            return try handler(testCase.input)
        } catch let error as SuiteError {
            throw error
        } catch {
            return .object(["outcome": .string("error"), "code": .string(errorCode(error))])
        }
    }

    /// Projection of the port's errors onto the spec §8 taxonomy.
    static func errorCode(_ error: any Error) -> String {
        switch error {
        case CryptoError.invalidKeyMaterial: return "crypto.invalidKeyMaterial"
        case CryptoError.encryptFailed: return "crypto.encryptFailed"
        case ProvisioningError.connection: return "provisioning.connection"
        case ProvisioningError.authenticationFailed: return "provisioning.authenticationFailed"
        case ProvisioningError.invalidData: return "provisioning.invalidData"
        case ProvisioningError.interfaceNotFound: return "provisioning.interfaceNotFound"
        case ProvisioningError.interfaceAmbiguous: return "provisioning.interfaceAmbiguous"
        case PayloadError.unresolvedPlaceholder: return "payload.unresolvedPlaceholder"
        default: return "unmapped: \(error)"
        }
    }

    /// Expected outcomes carry an informative `decimal` next to a double's
    /// bits; only the bits are normative (`spec/conformance.md` §3).
    static func normalizeExpected(_ json: JSON) -> JSON {
        switch json {
        case .object(var o):
            if o["type"] == .string("double") { o["decimal"] = nil }
            return .object(o.mapValues(normalizeExpected))
        case .array(let a):
            return .array(a.map(normalizeExpected))
        default:
            return json
        }
    }

    // MARK: - Projection helpers

    static let reject = JSON.object(["outcome": .string("reject")])

    static func ok(_ value: [String: JSON]) -> JSON {
        .object(["outcome": .string("ok"), "value": .object(value)])
    }

    static func tagged(_ value: GrentonValue) -> JSON {
        switch value {
        case .null: return .object(["type": .string("null")])
        case .bool(let b): return .object(["type": .string("bool"), "value": .bool(b)])
        case .int(let i): return .object(["type": .string("int"), "value": .string(String(i))])
        case .string(let s): return .object(["type": .string("string"), "value": .string(s)])
        case .double(let d):
            return .object(["type": .string("double"), "bits": .string(String(format: "%016llx", d.bitPattern))])
        }
    }

    static func untagged(_ json: JSON?) throws -> GrentonValue {
        guard let json, let type = json["type"]?.stringValue else { throw SuiteError("bad tagged value \(json ?? .null)") }
        switch type {
        case "null": return .null
        case "bool":
            if let b = json["value"]?.boolValue { return .bool(b) }
        case "int":
            if let s = json["value"]?.stringValue, let i = Int64(s) { return .int(i) }
        case "string":
            if let s = json["value"]?.stringValue { return .string(s) }
        case "double":
            if let bits = json["bits"]?.stringValue, let raw = UInt64(bits, radix: 16) {
                return .double(Double(bitPattern: raw))
            }
        default: break
        }
        throw SuiteError("bad tagged value \(json)")
    }

    static func optionalBool(_ value: Bool?) -> JSON {
        value.map(JSON.bool) ?? .null
    }

    static func hex(_ text: String) throws -> Data {
        guard text.count.isMultiple(of: 2) else { throw SuiteError("odd-length hex") }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw SuiteError("bad hex \(text)") }
            data.append(byte)
            index = next
        }
        return data
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSON {
    func string(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue else { throw SuiteError("missing string input `\(key)`") }
        return value
    }
}
