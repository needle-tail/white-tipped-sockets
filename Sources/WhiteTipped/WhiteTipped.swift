
#if canImport(Network) && canImport(Combine)
import Foundation
import Network
import OSLog
import Combine
import WTHelpers

@available(iOS 13, macOS 12, *)
public final actor WhiteTipped: NSObject {
    
    public struct NetworkConfiguration: Sendable {
        let headers: [String: String]
        let cookies: [HTTPCookie]
        var urlRequest: URLRequest?
        let pingInterval: TimeInterval
        let connectionTimeout: Int
        let url: URL
        let trustAll: Bool
        let certificates: [String]
        let maximumMessageSize: Int
        
        public init(
            headers: [String : String] = [:],
            cookies: [HTTPCookie] = [],
            urlRequest: URLRequest? = nil,
            pingInterval: TimeInterval = 1.0,
            connectionTimeout: Int = 7,
            url: URL,
            trustAll: Bool,
            certificates: [String] = [],
            maximumMessageSize: Int = 1_000_000 * 16
        ) {
            self.headers = headers
            self.cookies = cookies
            self.urlRequest = urlRequest
            self.pingInterval = pingInterval
            self.connectionTimeout = connectionTimeout
            self.url = url
            self.trustAll = trustAll
            self.certificates = certificates
            self.maximumMessageSize = maximumMessageSize
        }
        
    }
    public var configuration: NetworkConfiguration
    private var canRun: Bool = true
    private var connection: NWConnection
    @MainActor public var receiver: WhiteTippedReciever
    var nwQueue = DispatchQueue(label: "WTS", attributes: .concurrent)
    let connectionState = ObservableNWConnectionState()
    static let listernReceiver = ListenerReceiver()
    var stateCancellable: Cancellable?
    var betterPathCancellable: Cancellable?
    var viablePatheCancellable: Cancellable?
    weak var receiverDelegate: WhiteTippedRecieverDelegate?
    
    public func setDelegate(_ conformer: WhiteTippedRecieverDelegate) {
        self.receiverDelegate = conformer
    }
    
    public init(
        configuration: NetworkConfiguration,
        receiver: WhiteTippedReciever = WhiteTippedReciever()
    ) throws {
        
        self.configuration = configuration
        self.receiver = receiver
        
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = configuration.maximumMessageSize
        
        if configuration.urlRequest != nil {
            options.setAdditionalHeaders(configuration.urlRequest?.allHTTPHeaderFields?.map { ($0.key, $0.value) } ?? [])
            _ = configuration.cookies.map { cookie in
                options.setAdditionalHeaders([(name: cookie.name, value: cookie.value)])
            }
        }
        if !configuration.headers.isEmpty {
            options.setAdditionalHeaders(configuration.headers.map { ($0.key, $0.value) } )
        }
        
        let parameters: NWParameters = configuration.trustAll ? try TLSConfiguration.trustSelfSigned(nwQueue, certificates: configuration.certificates) : (configuration.url.scheme == "ws" ? .tcp : .tls)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(configuration.url), using: parameters)
        super.init()
    }
    
    func createLogger() async {
        if #available(iOS 14, macOS 12, *) {
            logger = Logger(subsystem: "WhiteTipped", category: "NWConnection")
        } else {
            oslog = OSLog(subsystem: "WhiteTipped", category: "NWConnection")
        }
    }
    
    deinit {
        //        print("RECLAIMING MEMORY IN WTS")
    }
    
    public func connect() async {
        await createLogger()
        connection.start(queue: nwQueue)
        canRun = true
        await pathHandlers()
        do {
            try await betterPath()
            try await viablePath()
            try await monitorConnection()
        } catch {
            if #available(iOS 14, macOS 12, *) {
                logger?.error("\(error)")
            } else {
                
            }
        }
    }
    
    private func pathHandlers() async {
        
        stateCancellable = connectionState.publisher(for: \.currentState) as? Cancellable
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {return}
            self.connectionState.currentState = state
        }
        
        betterPathCancellable = connectionState.publisher(for: \.betterPath) as? Cancellable
        connection.betterPathUpdateHandler = { [weak self] value in
            guard let self else {return}
            self.connectionState.betterPath = value
        }
        
        viablePatheCancellable = connectionState.publisher(for: \.viablePath) as? Cancellable
        connection.viabilityUpdateHandler = { [weak self] value in
            guard let self else {return}
            self.connectionState.viablePath = value
        }
    }
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    private func receiveMessage(connection: NWConnection) async throws {
        let listener = try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<ListenerStruct, Error>) in
            connection.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    let listener = ListenerStruct(data: completeContent, context: contentContext, isComplete: isComplete)
                    continuation.resume(returning: listener)
                }
            })
        })
        
        try await channelRead(listener: listener)
    }
    
    func channelRead(listener: ListenerStruct) async throws {
        guard let metadata = listener.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
        switch metadata.opcode {
        case .cont:
            if #available(iOS 14, macOS 12, *) {
                logger?.trace("Received continuous WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received continuous WebSocketFrame", log: oslog, type: .info)
            }
        case .text:
            if #available(iOS 14, macOS 12, *) {
                logger?.trace("Received text WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received text WebSocketFrame", log: oslog, type: .info)
            }
            guard let data = listener.data else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await receiverDelegate?.received(message: .text(text))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.textReceived = text
            }
        case .binary:
            if #available(iOS 14, macOS 12, *) {
                logger?.trace("Received binary WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received binary WebSocketFrame", log: oslog, type: .info)
            }
            guard let data = listener.data else { return }
            try await receiverDelegate?.received(message: .binary(data))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.binaryReceived = data
            }
        case .close:
            if #available(iOS 14, macOS 12, *) {
                logger?.trace("Received close WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received close WebSocketFrame", log: oslog, type: .info)
            }
            connection.cancel()
            try await notifyDisconnection(.protocolCode(.goingAway))
        case .ping:
            if #available(iOS 14, macOS 12, *) {
                logger?.trace("Received ping WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received ping WebSocketFrame", log: oslog, type: .info)
            }
            let data = Data()
            try await receiverDelegate?.received(message: .ping(data))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.pingReceived = data
            }
        case .pong:
            if #available(iOS 14, macOS 12, *) {
                logger?.trace("Received pong WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received pong WebSocketFrame", log: oslog, type: .info)
            }
            let data = Data()
            try await receiverDelegate?.received(message: .pong(data))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.pongReceived = data
            }
            do {
                try await ping()
            } catch {
                if #available(iOS 14, macOS 12, *) {
                    logger?.error("\(error)")
                } else {
                    guard let oslog = oslog else { return }
                    os_log("%@", log: oslog, type: .error, error.localizedDescription)
                }
            }
        @unknown default:
            fatalError("Unkown State Case")
        }
    }
    
    
    public func disconnect(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) async throws {
        canRun = false
        if code == .protocolCode(.normalClosure) {
            connection.cancel()
            try await notifyDisconnection(code)
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            try await notifyDisconnection(code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            try await send(data: Data(), context: context)
        }
        stateCancellable = nil
        betterPathCancellable = nil
        viablePatheCancellable = nil
    }
    
    func notifyDisconnection(with error: NWError? = nil, _ reason: NWProtocolWebSocket.CloseCode) async throws {
        let result = DisconnectResult(error: error, code: reason)
        try await receiverDelegate?.received(message: .disconnectPacket(result))
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receiver.disconnectionPacketReceived = result
        }
    }
    
    private func monitorConnection(_ betterPath: Bool = false) async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self else { return }
                if #available(iOS 15.0, *) {
                    for await state in self.connectionState.$currentState.values {
                        switch state {
                        case .setup:
                            await self.logger?.info("Connection setup")
                        case .waiting(let status):
                            await self.logger?.info("Connection waiting with status - Status: \(status.localizedDescription)")
                        case .preparing:
                            await self.logger?.info("Connection preparing")
                            if #available(iOS 16.0, macOS 13, *) {
                                let clock = ContinuousClock()
                                let time = clock.measure {
                                    while self.connectionState.currentState != .ready { }
                                }
                                
                                let state = await self.connection.state != .ready
                                if await time.components.seconds >= Int64(self.configuration.connectionTimeout) && state {
                                    await self.connection.stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
                                }
                            } else {
                                //TODO: DO OLDER API
                            }
                        case .ready:
                            await self.logger?.info("Connection established")
                            if betterPath == true {
                                await self.logger?.trace("We found a better path")
                                let parameters: NWParameters = await self.configuration.trustAll ? try TLSConfiguration.trustSelfSigned(nwQueue, certificates: self.configuration.certificates) : (self.configuration.url.scheme == "ws" ? .tcp : .tls)
                                let newConnection = await NWConnection(to: .url(self.configuration.url), using: parameters)
                                await newConnection.start(queue: nwQueue)
                                await self.pathHandlers()
                                await setNewConnection(newConnection)
                            }
                            try await self.receiverDelegate?.received(message: .connectionStatus(true))
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.receiver.connectionStatus = true
                            }
                            try await receiveMessage(connection: connection)
                        case .failed(let error):
                            await self.logger?.info("Connection failed with error - Error: \(error)")
                            await self.connection.cancel()
                            try await notifyDisconnection(with: error, .protocolCode(.abnormalClosure))
                            try await self.receiverDelegate?.received(message: .connectionStatus(false))
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.receiver.connectionStatus = false
                            }
                        case .cancelled:
                            await self.logger?.info("Connection cancelled")
                            try await self.notifyDisconnection(.protocolCode(.normalClosure))
                            try await self.receiverDelegate?.received(message: .connectionStatus(false))
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.receiver.connectionStatus = false
                            }
                        default:
                            await self.logger?.info("Connection default")
                        }
                    }
                } else {
                    
                }
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    private func setNewConnection(_ newConnection: NWConnection) async {
        self.connection = newConnection
    }
    
    private func betterPath() async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self else { return }
                if #available(iOS 15.0, *) {
                    for await result in connectionState.$betterPath.values {
                        try await self.receiverDelegate?.received(message: .betterPath(result))
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.receiver.betterPathReceived = result
                        }
                        return
                    }
                } else {
                    // Fallback on earlier versions
                }
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    private func viablePath() async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self else { return }
                if #available(iOS 15.0, *) {
                    for await result in connectionState.$viablePath.values {
                        try await self.receiverDelegate?.received(message: .viablePath(result))
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.receiver.viablePathReceived = result
                        }
                        return
                    }
                } else {
                    // Fallback on earlier versions
                }
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    public func sendText(_ text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await send(data: data, context: context)
    }
    
    public func sendBinary(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        try await send(data: data, context: context)
    }
    
    public func ping() async throws {
        let date = RunLoop.timeInterval(configuration.pingInterval)
        repeat {
            if #available(iOS 16.0, macOS 13, *) {
                try await Task.sleep(until: .now + .seconds(configuration.pingInterval), clock: .suspending)
            } else {
                try await Task.sleep(nanoseconds: NSEC_PER_SEC * UInt64(configuration.pingInterval))
            }
            if canRun {
                try await self.sendPing()
            }
        } while await RunLoop.execute(date, canRun: canRun)
    }
    
    public func pong() async throws {
        let date = RunLoop.timeInterval(configuration.pingInterval)
        repeat {
            if #available(iOS 16.0, macOS 13, *) {
                try await Task.sleep(until: .now + .seconds(configuration.pingInterval), clock: .suspending)
            } else {
                try await Task.sleep(nanoseconds: NSEC_PER_SEC * UInt64(configuration.pingInterval))
            }
            if canRun {
                try await sendPong()
            }
        } while await RunLoop.execute(date, canRun: canRun)
    }
    
    func sendPing() async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        try await self.pongHandler(metadata)
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [metadata]
        )
        guard let data = "ping".data(using: .utf8) else { return }
        try await self.send(data: data, context: context)
    }
    
    func sendPong() async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
        try await pongHandler(metadata)
        let context = NWConnection.ContentContext(
            identifier: "pong",
            metadata: [metadata]
        )
        guard let data = "ping".data(using: .utf8) else { return }
        try await send(data: data, context: context)
    }
    func pongHandler(_ metadata: NWProtocolWebSocket.Metadata) async throws {
        Task{
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
                metadata.setPongHandler(nwQueue) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            })
        }
    }
    
    func send(data: Data, context: NWConnection.ContentContext) async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask {
                try await self.sendAsync(data: data, context: context)
                try await self.receiveMessage(connection: self.connection)
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    func sendAsync(data: Data, context: NWConnection.ContentContext) async throws -> Void {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed({ error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }))
        })
    }
}
#endif


@available(iOS 14, macOS 12, *)
fileprivate var _logger: [ObjectIdentifier: Logger] = [:]
@available(iOS 14, macOS 12, *)
extension WhiteTipped {
    var logger: Logger? {
        get { return _logger[ObjectIdentifier(self)] }
        set { _logger[ObjectIdentifier(self)] = newValue }
    }
}

@available(iOS 13, macOS 12, *)
fileprivate var _oslog: [ObjectIdentifier: OSLog] = [:]
@available(iOS 13, macOS 12, *)
extension WhiteTipped {
    var oslog: OSLog? {
        get { return _oslog[ObjectIdentifier(self)] }
        set { _oslog[ObjectIdentifier(self)] = newValue }
    }
}
