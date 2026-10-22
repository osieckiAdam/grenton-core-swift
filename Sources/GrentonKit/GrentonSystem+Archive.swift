import Foundation
import GrentonDevices
import GrentonProvisioning
import GrentonRuntime

extension GrentonSystem {
    /// Creates the devices from an interface archive — the ZIP
    /// `ProvisioningClient` downloads, or one saved
    /// earlier. Nothing connects until `start()`.
    ///
    /// - Parameters:
    ///   - interfaceArchive: The archive as downloaded from Object Manager.
    ///   - socketFactory: How to open UDP connections to the CLUs. Keep the
    ///     default unless a CLU answers from a different address than the one
    ///     in the interface; then pass `AnySourceUdpSocketFactory()`.
    ///   - logger: Where the library reports problems. Silent by default.
    ///   - pingInterval: How often each CLU is checked.
    ///   - registerInterval: How often subscriptions are renewed and all values
    ///     re-read.
    ///   - responseTimeout: How long to wait for a CLU to answer a request.
    /// - Throws: `ProvisioningError.invalidData` when the archive is not an
    ///   interface, or an error if its encryption key is invalid.
    public init(
        interfaceArchive: Data,
        socketFactory: any UdpSocketFactory = NetworkUdpSocketFactory(),
        logger: GrentonLogger = .disabled,
        pingInterval: Duration = CluSession.defaultPingInterval,
        registerInterval: Duration = CluSession.defaultRegisterInterval,
        responseTimeout: Duration = .seconds(5)
    ) throws {
        try self.init(
            interface: try ProvisioningClient.parseInterfaceArchive(interfaceArchive),
            socketFactory: socketFactory, logger: logger, pingInterval: pingInterval,
            registerInterval: registerInterval, responseTimeout: responseTimeout)
    }
}
