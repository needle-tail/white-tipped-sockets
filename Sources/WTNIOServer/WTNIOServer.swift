import NIO
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOPosix
import Foundation

class WTNIOServer {
    
    let port: Int
    let host: String
    var group: EventLoopGroup
    var channel: Channel?
    var serverConfiguration: TLSConfiguration?
    
    init(
        port: Int,
        host: String
    ) {
        self.port = port
        self.host = host
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        do {
        let homePath = FileManager().currentDirectoryPath
        let certs = try NIOSSLCertificate.fromPEMFile(homePath + "/Certificates/fullchain.pem")
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: homePath + "/Certificates/privkey.pem", format: .pem)
        let source = NIOSSLPrivateKeySource.privateKey(key)
        self.serverConfiguration = TLSConfiguration.makeServerConfiguration(certificateChain: certs, privateKey: source)
        } catch {
            print(error)
        }
    }
    
    
    deinit {
        Task {
        await stop()
        }
    }
    
    func start() async {
        do {
            self.channel = try await makeChannel()
            guard let localAddress = channel?.localAddress else {
                fatalError("Address was unable to bind. Please check that the socket was not closed or that the address family was understood.")
            }
            print("Server started and listening on \(localAddress)")
            try await channel?.closeFuture.get()
        } catch {
            print(error)
        }
    }
    
    
    func stop() async {
        do {
            try await channel?.close().get()
            try self.group.syncShutdownGracefully()
        } catch {
            print(error)
        }
    }
    
    func makeChannel() async throws -> Channel {
        return try await serverBootstrap()
            .bind(host: self.host, port: self.port)
            .get()
    }
    
    
    
    private func serverBootstrap() throws -> ServerBootstrap {
        let bootstrap = ServerBootstrap(group: group)
        // Specify backlog and enable SO_REUSEADDR for the server itself
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return try! self.makeHandler(channel: channel)
            }
        // Enable SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        return bootstrap
    }

    func makeHandler(channel: Channel) throws -> EventLoopFuture<Void> {

        if let config = self.serverConfiguration {
            let sslContext = try NIOSSLContext(configuration: config)

            let handler = NIOSSLServerHandler(context: sslContext)
            _ = channel.pipeline.addHandler(handler)
        }

        /// Initialize our WS Upgrader for the Server and add our WSHandler to it
        let websocketUpgrader = NIOWebSocketServerUpgrader { channel, req in
            channel.eventLoop.makeSucceededFuture([:])
        } upgradePipelineHandler: { channel, _ in
            channel.pipeline.addHandler(WebSocketHandler())
        }

        return channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (
                upgraders: [websocketUpgrader],
                completionHandler: { ctx in
                    print("Completed Setup")
                }
            )
        )
    }
}
