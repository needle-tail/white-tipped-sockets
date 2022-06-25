import NIO
import NIOHTTP1
import NIOWebSocket
import NIOSSL
import NIOPosix
import Foundation
import DotEnv

public actor WTNIOServer {
    
    let port: Int
    let host: String
    var group: EventLoopGroup
    var channel: Channel?
    var serverConfiguration: TLSConfiguration?
    
    public init(
        port: Int,
        host: String
    ) {
        self.port = port
        self.host = host
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }
    
    
    deinit {
        Task {
        await stop()
        }
    }
    
    public func addTLS() {
        do {
        let basePath = FileManager().currentDirectoryPath
        let path = basePath + "/.env"
        _ = try DotEnv.load(path: path)
        let fullChain = ProcessInfo.processInfo.environment["FULL_CHAIN"] ?? ""
        let privKey = ProcessInfo.processInfo.environment["PRIV_KEY"] ?? ""
        let certPath = basePath + fullChain
        let keyPath = basePath + privKey
        let certs = try NIOSSLCertificate.fromPEMFile(certPath)
            .map { NIOSSLCertificateSource.certificate($0) }
        let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
        let source = NIOSSLPrivateKeySource.privateKey(key)
        self.serverConfiguration = TLSConfiguration.makeServerConfiguration(certificateChain: certs, privateKey: source)
        } catch {
            print(error)
        }
    }
    
    public func start() async {
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
    
    
    public func stop() async {
        do {
            try await channel?.close().get()
            try self.group.syncShutdownGracefully()
        } catch {
            print(error)
        }
    }
    
    public func makeChannel() async throws -> Channel {
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
                let promise = channel.eventLoop.makePromise(of: Void.self)
                promise.completeWithTask {
                try! await self.makeHandler(channel: channel)
                }
                return promise.futureResult
            }
        // Enable SO_REUSEADDR for the accepted Channels
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        return bootstrap
    }

    func makeHandler(channel: Channel) async throws {

        if let config = self.serverConfiguration {
            let sslContext = try NIOSSLContext(configuration: config)

            let handler = NIOSSLServerHandler(context: sslContext)
            try await channel.pipeline.addHandler(handler)
        }

        /// Initialize our WS Upgrader for the Server and add our WSHandler to it
        let websocketUpgrader = NIOWebSocketServerUpgrader { channel, req in
            channel.eventLoop.makeSucceededFuture([:])
        } upgradePipelineHandler: { channel, _ in
            let socket = WebSocket(channel: channel)
           return channel.pipeline.addHandler(WebSocketHandler(websocket: socket))
        }

        try await channel.pipeline.configureHTTPServerPipeline(
            withServerUpgrade: (
                upgraders: [websocketUpgrader],
                completionHandler: { ctx in
                    print("Completed Setup")
                }
            )
        ).get()
    }
    
    public static func server(
        on channel: Channel,
        onUpgrade: @escaping (WebSocketHandler) async -> ()
    ) async throws {
        let socket = WebSocket(channel: channel)
        let webSocket = WebSocketHandler(websocket: socket)
        try await channel.pipeline.addHandler(webSocket)
        await onUpgrade(webSocket)
    }
}
