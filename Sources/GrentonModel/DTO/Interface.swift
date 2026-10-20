import Foundation

// Diagnostic record for a widget element that failed to decode and was
// skipped (spec §3.6 requires the skip to be observable, not silent).
/// A widget the library could not read: an unknown type, or data missing.
public struct SkippedWidgetDiagnostic: Sendable {
    // The element's `type` discriminator, when it could be read.
    /// The widget's type, when it could be read.
    public let type: String?
    // Human-readable decoding failure description.
    /// Why it was skipped, for logs.
    public let reason: String
}

// A `HEADER` widget (spec §3.5): layout only, no device. Kept so an app
// can render the section titles between widgets.
/// A section title between widgets on a page.
public struct SectionHeaderDTO: Sendable {
    /// The widget's stable identifier.
    public let id: String
    /// The title text.
    public let label: String
}

/// One element of a page, in layout order.
public enum PageItemDTO: Sendable {
    /// A widget the library understands.
    case widget(WidgetDTO)
    /// A section title.
    case header(SectionHeaderDTO)
}

// A page of the mobile interface. Widgets decode lossily (spec §3.6):
// an element that fails — unknown `type`, missing field, unknown enum
// value — is skipped and the rest of the page survives. Skips are
// recorded in `skippedWidgets` for the consumer to log.
/// A page of the mobile interface.
public struct PageDTO: Decodable, Sendable {
    /// The page title.
    public let name: String
    public let icon: String
    public let isFullscreenWidget: Bool
    /// Widgets and section headers in layout order.
    public let items: [PageItemDTO]
    /// Widgets that could not be read.
    public let skippedWidgets: [SkippedWidgetDiagnostic]

    /// The widgets the library understands, in order.
    public var widgets: [WidgetDTO] {
        items.compactMap { if case .widget(let w) = $0 { return w } else { return nil } }
    }

    enum CodingKeys: String, CodingKey {
        case name, icon, isFullscreenWidget, widgets
    }

    /// Reads `type`, `id` and a header's first label leniently while
    /// consuming the whole object element.
    private struct TypeProbe: Decodable {
        let type: String?
        let id: String?
        let headerLabel: String?

        private struct Component: Decodable {
            let label: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyCodingKey.self)
                label = try? c.decode(String.self, forKey: AnyCodingKey(stringValue: "label")!)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            type = try? c.decode(String.self, forKey: AnyCodingKey(stringValue: "type")!)
            id = try? c.decode(String.self, forKey: AnyCodingKey(stringValue: "id")!)
            headerLabel = (try? c.decode([Component].self, forKey: AnyCodingKey(stringValue: "components")!))?
                .first?.label
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        isFullscreenWidget = try c.decode(Bool.self, forKey: .isFullscreenWidget)

        var raw = try c.nestedUnkeyedContainer(forKey: .widgets)
        var accepted: [PageItemDTO] = []
        var skipped: [SkippedWidgetDiagnostic] = []
        while !raw.isAtEnd {
            do {
                accepted.append(.widget(try raw.decode(WidgetDTO.self)))
            } catch {
                let reason = String(describing: error)
                if let probe = try? raw.decode(TypeProbe.self) {
                    if let type = probe.type, WidgetDTO.presentationalTypes.contains(type) {
                        // A section header needs its id and first label
                        // (spec §3.5); without them it is skipped like any widget.
                        if let id = probe.id, let label = probe.headerLabel {
                            accepted.append(.header(SectionHeaderDTO(id: id, label: label)))
                        } else {
                            skipped.append(SkippedWidgetDiagnostic(type: type, reason: "header without id or label"))
                        }
                        continue
                    }
                    skipped.append(SkippedWidgetDiagnostic(type: probe.type, reason: reason))
                } else if (try? raw.decode(JSONSkip.self)) != nil {
                    skipped.append(SkippedWidgetDiagnostic(type: nil, reason: reason))
                } else {
                    // Cannot advance past this element — bail out rather than spin.
                    break
                }
            }
        }
        items = accepted
        skippedWidgets = skipped
    }
}

// Root of `mygrenton/data.json` (spec §3.4).
/// The mobile interface exactly as Object Manager exports it: CLUs, encryption and pages of widgets.
public struct MobileInterfaceDTO: Decodable, Sendable {
    /// Identifies the installation. It stays the same across exports.
    public let id: String
    /// Changes with every export from Object Manager.
    public let version: Int
    /// The interface name.
    public let name: String
    public let icon: String
    public let theme: GrentonTheme
    public let encryption: EncryptionDTO
    /// Every CLU of the installation.
    public let clus: [CluDTO]
    /// The pages, in order.
    public let pages: [PageDTO]
    public let pushNotifications: [PushNotificationDTO]

    // All widgets across all pages, in page order (spec §6.1: pages are
    // only a container — the device layer flattens them).
    /// The widgets of every page, in page order.
    public var allWidgets: [WidgetDTO] {
        pages.flatMap(\.widgets)
    }

    // Diagnostics for every widget skipped during decoding, across pages.
    /// Widgets that could not be read, on every page.
    public var skippedWidgets: [SkippedWidgetDiagnostic] {
        pages.flatMap(\.skippedWidgets)
    }

    // Decodes a `data.json` payload.
    /// Reads an interface from its JSON (`data.json`).
    public static func decode(from data: Data) throws -> MobileInterfaceDTO {
        try JSONDecoder().decode(MobileInterfaceDTO.self, from: data)
    }
}
