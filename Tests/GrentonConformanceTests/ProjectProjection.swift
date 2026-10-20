import Foundation
import GrentonModel

/// JSON projection of an imported interface's root (`spec/conformance.md`
/// §4c): the root fields, the CLUs, the push objects, and per page the
/// `{id, type}` of every widget and section header that parsed.
enum ProjectProjection {
    static func root(_ interface: MobileInterfaceDTO) -> JSON {
        .object([
            "id": .string(interface.id),
            "version": .number(Double(interface.version)),
            "name": .string(interface.name),
            "icon": .string(interface.icon),
            "theme": .string(interface.theme.rawValue),
            "encryption": .object(["key": .string(interface.encryption.key), "iv": .string(interface.encryption.iv)]),
            "clus": .array(interface.clus.map { clu in
                .object([
                    "id": .string(clu.id), "name": .string(clu.name), "ip": .string(clu.ip),
                    "serialNumber": .string(clu.serialNumber), "port": .number(Double(clu.port)),
                    "connectionType": .string(clu.connectionType.rawValue),
                ])
            }),
            "pushNotifications": .array(interface.pushNotifications.map { push in
                .object(["cluId": .number(Double(push.cluId)), "objectId": .string(push.objectId),
                         "objectType": .string(push.objectType)])
            }),
            "pages": .array(interface.pages.map { page in
                .object([
                    "name": .string(page.name), "icon": .string(page.icon),
                    "isFullscreenWidget": .bool(page.isFullscreenWidget),
                    "widgets": .array(page.items.map { item in
                        switch item {
                        case .widget(let w): return .object(["id": .string(w.id), "type": .string(w.typeName)])
                        case .header(let h): return .object(["id": .string(h.id), "type": .string("HEADER")])
                        }
                    }),
                ])
            }),
        ])
    }
}
