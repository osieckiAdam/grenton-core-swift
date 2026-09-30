import Foundation

/// Diagnostic record for a widget element that failed to decode and was
/// skipped (spec §3.6 requires the skip to be observable, not silent).
public struct SkippedWidgetDiagnostic: Sendable {
    /// The element's `type` discriminator, when it could be read.
    public let type: String?
    /// Human-readable decoding failure description.
    public let reason: String
}

/// A page of the mobile interface. Widgets decode lossily (spec §3.6):
/// an element that fails — unknown `type`, missing field, unknown enum
/// value — is skipped and the rest of the page survives. Skips are
/// recorded in `skippedWidgets` for the consumer to log.
public struct PageDTO: Decodable, Sendable {
    public let name: String
    public let icon: String
    public let isFullscreenWidget: Bool
    public let widgets: [WidgetDTO]
    public let skippedWidgets: [SkippedWidgetDiagnostic]

    enum CodingKeys: String, CodingKey {
        case name, icon, isFullscreenWidget, widgets
    }

    /// Reads only the `type` field while consuming the whole object element.
    private struct TypeProbe: Decodable {
        let type: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decode(String.self, forKey: .icon)
        isFullscreenWidget = try c.decode(Bool.self, forKey: .isFullscreenWidget)

        var raw = try c.nestedUnkeyedContainer(forKey: .widgets)
        var accepted: [WidgetDTO] = []
        var skipped: [SkippedWidgetDiagnostic] = []
        while !raw.isAtEnd {
            do {
                accepted.append(try raw.decode(WidgetDTO.self))
            } catch {
                let reason = String(describing: error)
                if let probe = try? raw.decode(TypeProbe.self) {
                    // Section headers are known layout, not a failure.
                    if let type = probe.type, WidgetDTO.presentationalTypes.contains(type) { continue }
                    skipped.append(SkippedWidgetDiagnostic(type: probe.type, reason: reason))
                } else if (try? raw.decode(JSONSkip.self)) != nil {
                    skipped.append(SkippedWidgetDiagnostic(type: nil, reason: reason))
                } else {
                    // Cannot advance past this element — bail out rather than spin.
                    break
                }
            }
        }
        widgets = accepted
        skippedWidgets = skipped
    }
}

/// Root of `mygrenton/data.json` (spec §3.4).
public struct MobileInterfaceDTO: Decodable, Sendable {
    public let id: String
    public let version: Int
    public let name: String
    public let icon: String
    public let theme: GrentonTheme
    public let encryption: EncryptionDTO
    public let clus: [CluDTO]
    public let pages: [PageDTO]
    public let pushNotifications: [PushNotificationDTO]

    /// All widgets across all pages, in page order (spec §6.1: pages are
    /// only a container — the device layer flattens them).
    public var allWidgets: [WidgetDTO] {
        pages.flatMap(\.widgets)
    }

    /// Diagnostics for every widget skipped during decoding, across pages.
    public var skippedWidgets: [SkippedWidgetDiagnostic] {
        pages.flatMap(\.skippedWidgets)
    }

    /// Decodes a `data.json` payload.
    public static func decode(from data: Data) throws -> MobileInterfaceDTO {
        try JSONDecoder().decode(MobileInterfaceDTO.self, from: data)
    }
}
