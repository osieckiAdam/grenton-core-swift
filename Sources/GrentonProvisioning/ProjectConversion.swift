import Foundation

// Conversion of an interface from Object Manager's editor format to the
// mobile schema (spec §4.5.3–§4.5.6), plus the CLU list and push objects
// read from `system.xml`. Pure functions over `JSONValue` and
// `XmlDocument`; the result is serialized and decoded like a downloaded
// `data.json`.
enum ProjectConversion {
    static let cluPort: Int64 = 1234

    /// A converted page tree and the `cluId`s its references and actions name
    /// (spec §4.5.4: only those CLUs make the list).
    struct Pages {
        var pages: [JSONValue] = []
        var usedCluIds: Set<String> = []
    }

    // MARK: Pages and widgets (§4.5.6)

    static func pages(_ editorPages: [JSONValue]) throws -> Pages {
        var out = Pages()
        for page in editorPages {
            guard let label = page["label"]?.stringValue, let icon = page["icon"]?.stringValue,
                  let widgets = page["widgets"]?.arrayValue else {
                throw ProvisioningError.invalidData("a page lacks label, icon or widgets")
            }
            let converted = widgets.map { widget($0, used: &out.usedCluIds) }
            out.pages.append(.object([
                ("name", .string(label)), ("icon", .string(icon)),
                ("isFullscreenWidget", .bool(false)), ("widgets", .array(converted)),
            ]))
        }
        return out
    }

    /// A field the conversion needs is missing: the widget becomes a stub.
    private struct Missing: Error {}

    static func widget(_ w: JSONValue, used: inout Set<String>) -> JSONValue {
        do {
            return try convertWidget(w, used: &used)
        } catch {
            var stub: [(String, JSONValue)] = []
            if let id = w["dtoId"]?.stringValue { stub.append(("id", .string(id))) }
            if let type = w["type"]?.stringValue { stub.append(("type", .string(type))) }
            return .object(stub)
        }
    }

    private static func need(_ w: JSONValue, _ key: String) throws -> JSONValue {
        guard let value = w.required(key) else { throw Missing() }
        return value
    }

    private static func needObject(_ w: JSONValue, _ key: String) throws -> JSONValue {
        let value = try need(w, key)
        guard value.isObject else { throw Missing() }
        return value
    }

    private static func convertWidget(_ w: JSONValue, used: inout Set<String>) throws -> JSONValue {
        guard w.isObject, let type = try need(w, "type").stringValue, let id = try need(w, "dtoId").stringValue else {
            throw Missing()
        }
        var out: [(String, JSONValue)] = [("id", .string(id)), ("type", .string(type))]
        switch type {
        case "HEADER":
            let text = try needObject(w, "text")
            var component: [(String, JSONValue)] = [("unit", .string("UNKNOWN"))]
            copy(["label", "type", "rowId"], from: text, into: &component)
            out.append(("components", .array([.object(component)])))
        case "ON_OFF":
            out.append(("components", .array([bistable(try needObject(w, "buttonBistable"), used: &used)])))
        case "ON_OFF_DOUBLE":
            out.append(("components", .array([
                bistable(try needObject(w, "buttonBistableFirst"), used: &used),
                bistable(try needObject(w, "buttonBistableSecond"), used: &used),
            ])))
        case "SCENE":
            out.append(("components", .array([monostable(try needObject(w, "buttonMonostable"), used: &used)])))
            addBackground(w, into: &out)
        case "SCENE_DOUBLE":
            out.append(("components", .array([
                monostable(try needObject(w, "buttonMonostableFirst"), used: &used),
                monostable(try needObject(w, "buttonMonostableSecond"), used: &used),
            ])))
            addBackground(w, into: &out)
        case "VALUE_V2":
            out += valueFields(w, used: &used)
        case "VALUE_DOUBLE":
            out.append(("componentLeft", .object(valueFields(try needObject(w, "componentLeft"), used: &used))))
            out.append(("componentRight", .object(valueFields(try needObject(w, "componentRight"), used: &used))))
        case "DIMMER_V2":
            copy(["min", "max", "precision", "icon", "label"], from: w, into: &out)
            out.append(("object", objectBlock(try needObject(w, "object"), used: &used)))
        case "THERMOSTAT_V2":
            copy(["icon", "label"], from: w, into: &out)
            if let fans = w["noOfFanSpeeds"] { out.append(("no_of_fan_speeds", fans)) }
            out.append(("object", objectBlock(try needObject(w, "object"), used: &used)))
        case "ROLLER_SHUTTER_V3", "EVENT_SCHEDULER":
            copy(["icon", "label"], from: w, into: &out)
            out.append(("object", objectBlock(try needObject(w, "object"), used: &used)))
        default:
            throw Missing()
        }
        return .object(out)
    }

    /// Copies the fields that are present, `null` included (spec §4.5.6).
    private static func copy(_ keys: [String], from source: JSONValue, into out: inout [(String, JSONValue)]) {
        for key in keys {
            if let value = source[key] { out.append((key, value)) }
        }
    }

    /// A reference or action exists when it is an object with a non-empty `objectName`.
    private static func exists(_ r: JSONValue?) -> Bool {
        guard let r, r.isObject, let name = r["objectName"]?.stringValue else { return false }
        return !name.isEmpty
    }

    private static func noteClu(_ r: JSONValue, used: inout Set<String>) {
        if let cluId = r["cluId"]?.stringValue { used.insert(cluId) }
    }

    private static func ref(_ r: JSONValue?, used: inout Set<String>) -> JSONValue? {
        guard let r, exists(r) else { return nil }
        var out: [(String, JSONValue)] = []
        copy(["cluId", "objectName", "index", "callType"], from: r, into: &out)
        noteClu(r, used: &used)
        return .object(out)
    }

    private static func isAction(_ v: JSONValue) -> Bool {
        v.isObject && v.has("valueFormattedForDto")
    }

    private static func action(_ a: JSONValue?, used: inout Set<String>) -> JSONValue? {
        guard let a, exists(a) else { return nil }
        var out: [(String, JSONValue)] = []
        copy(["cluId", "objectName"], from: a, into: &out)
        if let index = a.required("index") { out.append(("index", index)) }
        if let event = a["type"] { out.append(("event", event)) }
        copy(["value"], from: a, into: &out)
        if let callType = a["callType"] {
            out.append(("callType", callType.stringValue == "PSEUDO_METHOD" ? .string("ATTRIBUTE") : callType))
        }
        noteClu(a, used: &used)
        return .object(out)
    }

    private static func bistable(_ b: JSONValue, used: inout Set<String>) -> JSONValue {
        var out: [(String, JSONValue)] = [("unit", .string("UNKNOWN"))]
        copy(["image", "label", "onIndication", "offIndication", "type", "rowId"], from: b, into: &out)
        if let state = ref(b["state"], used: &used) { out.append(("state", state)) }
        let actions = [action(b["actionOn"], used: &used), action(b["actionOff"], used: &used)].compactMap { $0 }
        out.append(("actions", .array(actions)))
        return .object(out)
    }

    private static func monostable(_ m: JSONValue, used: inout Set<String>) -> JSONValue {
        var out: [(String, JSONValue)] = [("unit", .string("UNKNOWN"))]
        copy(["label", "type", "rowId"], from: m, into: &out)
        out.append(("actions", .array([action(m["actionClick"], used: &used)].compactMap { $0 })))
        return .object(out)
    }

    private static func addBackground(_ w: JSONValue, into out: inout [(String, JSONValue)]) {
        guard let b = w["background"], b.isObject else { return }
        var background: [(String, JSONValue)] = []
        if let color = b["color"] {
            background.append(("color", color.stringValue.map { .string($0.uppercased()) } ?? color))
        }
        if let image = b["image"] { background.append(("name", image)) }
        out.append(("background", .object(background)))
    }

    private static func valueFields(_ c: JSONValue, used: inout Set<String>) -> [(String, JSONValue)] {
        var out: [(String, JSONValue)] = []
        copy(["unit", "valueType", "precision", "icon", "label"], from: c, into: &out)
        var object: [(String, JSONValue)] = []
        if let value = ref(c["value"], used: &used) { object.append(("value", value)) }
        out.append(("object", .object(object)))
        return out
    }

    /// O of spec §4.5.6: references keep their name, actions get the
    /// `Action` suffix, and a field already named as the target wins over
    /// a bare-named action whatever the member order.
    private static func objectBlock(_ obj: JSONValue, used: inout Set<String>) -> JSONValue {
        var out: [(String, JSONValue)] = []
        let members = obj.members ?? []
        for (name, value) in members where value.isObject {        // pass 1: fields keeping their name
            if isAction(value) {
                if name.hasSuffix("Action"), let converted = action(value, used: &used) {
                    out.append((name, converted))
                }
            } else if let converted = ref(value, used: &used) {
                out.append((name, converted))
            }
        }
        for (name, value) in members where isAction(value) && !name.hasSuffix("Action") {   // pass 2: bare names
            let target = name + "Action"
            guard !obj.has(target), let converted = action(value, used: &used) else { continue }
            out.append((target, converted))
        }
        return .object(out)
    }

    // MARK: CLUs (§4.5.4)

    static func clus(in system: XmlDocument, used: Set<String>, blockCloud: Bool) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var seen: Set<String> = []
        for index in system.nodes.indices {
            guard !system.children(of: index, named: "nameOnCLU").isEmpty,
                  !system.children(of: index, named: "ipAddress").isEmpty,
                  let cluId = try system.text(of: index, child: "nameOnCLU"),
                  seen.insert(cluId).inserted,
                  used.contains(cluId) else { continue }
            guard let name = try system.text(of: index, child: "name"),
                  let ip = try system.text(of: index, child: "ipAddress"),
                  let serial = XmlDocument.hexNumber(try system.text(of: index, child: "serialNumber")) else {
                throw ProvisioningError.invalidData("CLU \(cluId) lacks name, ipAddress or serialNumber")
            }
            out.append(.object([
                ("id", .string(cluId)), ("name", .string(name)), ("ip", .string(ip)),
                ("serialNumber", .string(String(serial))), ("port", .int(cluPort)),
                ("connectionType", .string(blockCloud ? "LOCAL_ONLY" : "CLOUD")),
            ]))
        }
        return out
    }

    // MARK: Push notifications (§4.5.5)

    static func pushNotifications(in system: XmlDocument) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var visited: Set<Int> = []
        // Depth-first, node before children, iterative: (node, serial of the nearest CLU ancestor).
        var stack: [(Int, UInt64?)] = system.children(of: system.root, named: "TreeObject").reversed().map { ($0, nil) }
        while let (raw, serial) = stack.popLast() {
            let node = try system.resolve(raw)
            guard visited.insert(node).inserted else { continue }
            let object = try system.child(of: node, named: "specificObject")
            if let object, try system.text(of: object, child: "typeName") == "Push",
               let serial,
               let objectId = try system.text(of: object, child: "nameOnCLU"),
               let typeId = XmlDocument.hexNumber(try system.text(of: object, child: "typeId")),
               let version = try system.text(of: object, child: "typeVersion") {
                out.append(.object([
                    ("cluId", .int(Int64(serial))), ("objectId", .string(objectId)),
                    ("objectType", .string("PUSH-\(typeId)-\(version)")),
                ]))
            }
            var here = serial
            if let object, !system.children(of: object, named: "serialNumber").isEmpty,
               !system.children(of: object, named: "ipAddress").isEmpty {
                here = XmlDocument.hexNumber(try system.text(of: object, child: "serialNumber"))
            }
            if let children = try system.child(of: node, named: "children") {
                stack += system.children(of: children, named: "TreeObject").reversed().map { ($0, here) }
            }
        }
        return out
    }
}
