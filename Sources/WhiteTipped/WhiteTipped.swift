
#if canImport(Network) && canImport(Combine)
import Foundation
import Network
import OSLog
import Combine
import WTHelpers

@available(iOS 16, macOS 13, *)
public final actor AsyncWhiteTipped: NSObject {
    
    public var headers: [String: String]?
    public var urlRequest: URLRequest?
    public var cookies: [HTTPCookie]
    private var canRun: Bool = true
    private var connection: NWConnection?
    private var parameters: NWParameters?
    private var endpoint: NWEndpoint?
    let logger: Logger = Logger(subsystem: "WhiteTipped", category: "NWConnection")
    private var consumer = ListenerConsumer()
    @MainActor public var receiver = WhiteTippedReciever()
    var pingInterval: TimeInterval = 1.0
    var connectionTimeout: Int = 7
    weak var receiverDelegate: WhiteTippedRecieverProtocol?
    public func setDelegate(_ conformer: WhiteTippedRecieverProtocol) {
        self.receiverDelegate = conformer
    }
    
    
    public init(
        headers: [String: String] = [:],
        urlRequest: URLRequest? = nil,
        cookies: [HTTPCookie] = [],
        pingInterval: TimeInterval,
        connectionTimeout: Int
    ) {
        self.headers = headers
        self.urlRequest = urlRequest
        self.cookies = cookies
        self.pingInterval = pingInterval
        self.connectionTimeout = connectionTimeout
    }
    
    
    var nwQueue = DispatchQueue(label: "WTS")
    let connectionState = ObservableNWConnectionState()
    var stateCancellable: Cancellable?
    var betterPathCancellable: Cancellable?
    var viablePatheCancellable: Cancellable?
    
    
    public func connect(url: URL, trustAll: Bool, certificates: [String]?) async {
        canRun = true
        endpoint = .url(url)
        
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        //Limit Message size to 16MB to prevent abuse
        options.maximumMessageSize = 1_000_000 * 16
        
        if urlRequest != nil {
            options.setAdditionalHeaders(urlRequest?.allHTTPHeaderFields?.map { ($0.key, $0.value) } ?? [])
            _ = self.cookies.map { cookie in
                options.setAdditionalHeaders([(name: cookie.name, value: cookie.value)])
            }
        }
        if headers != nil {
            options.setAdditionalHeaders(headers?.map { ($0.key, $0.value) } ?? [])
        }
        if trustAll {
            parameters = try? TLSConfiguration.trustSelfSigned(nwQueue, certificates: certificates, logger: logger)
        } else {
            parameters = (url.scheme == "ws" ? .tcp : .tls)
        }
        
        parameters?.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        
        guard let endpoint = endpoint else { return }
        guard let parameters = parameters else { return }
        connection = NWConnection(to: endpoint, using: parameters)
        connection?.start(queue: nwQueue)
        
        await pathHandlers()
        await monitorConnection()
        await betterPath()
        await viablePath()
    }
    
    
    private func pathHandlers() async {
        stateCancellable = connectionState.publisher(for: \.currentState) as? Cancellable
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self else {return}
            self.connectionState.currentState = state
        }
        
        betterPathCancellable = connectionState.publisher(for: \.betterPath) as? Cancellable
        connection?.betterPathUpdateHandler = { [weak self] value in
            guard let self else {return}
            self.connectionState.betterPath = value
        }
        
        viablePatheCancellable = connectionState.publisher(for: \.viablePath) as? Cancellable
        connection?.viabilityUpdateHandler = { [weak self] value in
            guard let self else {return}
            self.connectionState.viablePath = value
        }
    }
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    
    private func receiveAndFeed() {
        connection?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
            let listener = ListenerStruct(data: completeContent, context: contentContext, isComplete: isComplete)
            
            Task { [weak self] in
                guard let self else { return }
                await self.consumer.feedConsumer(listener)
                do {
                    try await self.channelRead()
                } catch {
                    self.logger.error("Error Reading Channel: \(error.localizedDescription)")
                }
            }
            if error == nil {
                self.receiveAndFeed()
            }
        })
    }
    
    
    private func channelRead() async throws {
        do {
            for try await result in ListenerSequence(consumer: consumer) {
                switch result {
                case .success(let listener):
                    guard let metadata = listener.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
                    switch metadata.opcode {
                    case .cont:
                        logger.trace("Received continuous WebSocketFrame")
                    case .text:
                        logger.trace("Received text WebSocketFrame")
                        guard let data = listener.data else { return }
                        guard let text = String(data: data, encoding: .utf8) else { return }
                        receiverDelegate?.received(.text, packet: MessagePacket(text: text))
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.receiver.textReceived = text
                        }
                    case .binary:
                        logger.trace("Received binary WebSocketFrame")
                        guard let data = listener.data else { return }
                        receiverDelegate?.received(.binary, packet: MessagePacket(binary: data))
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.receiver.binaryReceived = data
                        }
                    case .close:
                        logger.trace("Received close WebSocketFrame")
                        connection?.cancel()
                        await notifyDisconnection(.protocolCode(.goingAway))
                    case .ping:
                        logger.trace("Received ping WebSocketFrame")
                    case .pong:
                        logger.trace("Received pong WebSocketFrame")
                    @unknown default:
                        fatalError("Unkown State Case")
                    }
                case .finished:
                    logger.trace("Finished")
                    return
                case .retry:
                    logger.trace("Will retry")
                    return
                }
                
            }
        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
    
    
    public func disconnect(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) async throws {
        canRun = false
        if code == .protocolCode(.normalClosure) {
            connection?.cancel()
            await notifyDisconnection(code)
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            await notifyDisconnection(code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            try await send(data: nil, context: context)
        }
        
        stateCancellable = nil
        betterPathCancellable = nil
        viablePatheCancellable = nil
    }
    
    
    func notifyDisconnection(with error: NWError? = nil, _ reason: NWProtocolWebSocket.CloseCode) async {
        let result = DisconnectResult(error: error, code: reason)
        receiverDelegate?.received(.disconnectPacket, packet: MessagePacket(disconnectPacket: result))
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receiver.disconnectionPacketReceived = result
        }
    }
    
    
    private func monitorConnection(_ betterPath: Bool = false) async  {
        //AsyncPublish prevents currentState from finishing the suspension
        for await state in connectionState.$currentState.values {
            switch state {
            case .setup:
                logger.info("Connection setup")
            case .waiting(let status):
                logger.info("Connection waiting with status - Status: \(status.localizedDescription)")
            case .preparing:
                logger.info("Connection preparing")
                Task.detached { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(until: .now + .seconds(self.connectionTimeout), clock: .suspending)
                        if await self.connection?.state != .ready {
                            await self.connection?.stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
                        }
                    } catch {
                        self.logger.error("\(error.localizedDescription)")
                    }
                }
            case .ready:
                logger.info("Connection established")
                if betterPath == true {
                    logger.trace("We found a better path")
                    self.connection = nil
                    guard let endpoint = endpoint else { return }
                    guard let parameters = parameters else { return }
                    let newConnection = NWConnection(to: endpoint, using: parameters)
                    newConnection.start(queue: nwQueue)
                    await pathHandlers()
                    self.connection = newConnection
                }
                receiveAndFeed()
                receiverDelegate?.received(.connectionStatus, packet: MessagePacket(connectionStatus: true))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.receiver.connectionStatus = true
                }
            case .failed(let error):
                logger.info("Connection failed with error - Error: \(error.localizedDescription)")
                connection?.cancel()
                await notifyDisconnection(with: error, .protocolCode(.abnormalClosure))
                receiverDelegate?.received(.connectionStatus, packet: MessagePacket(connectionStatus: false))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.receiver.connectionStatus = false
                }
            case .cancelled:
                logger.info("Connection cancelled")
                await notifyDisconnection(.protocolCode(.normalClosure))
                receiverDelegate?.received(.connectionStatus, packet: MessagePacket(connectionStatus: false))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.receiver.connectionStatus = false
                }
            default:
                logger.info("Connection default")
                return
            }
        }
    }
    
    
    private func betterPath() async {
        for await result in connectionState.$betterPath.values {
            receiverDelegate?.received(.betterPath, packet: MessagePacket(betterPath: result))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.betterPathReceived = result
            }
            break
        }
    }
    
    
    private func viablePath() async {
        for await result in connectionState.$viablePath.values {
            receiverDelegate?.received(.viablePath, packet: MessagePacket(viablePath: result))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.viablePathReceived = result
            }
            break
        }
    }
    
    
    public func sendText(_ text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await send(data: data, context: context)
    }
    
    
    public func sendBinary(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await send(data: data, context: context)
    }
    
    public func ping(interval: TimeInterval) async throws {
        let date = RunLoop.timeInterval(interval)
        repeat {
            try await Task.sleep(nanoseconds: NSEC_PER_SEC * UInt64(interval))
            if canRun {
                try await sendPing()
            }
        } while await RunLoop.execute(date, canRun: canRun)
    }
    
    
    func sendPing() async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        pongHandler(metadata)
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [metadata]
        )
        try await send(data: "ping".data(using: .utf8), context: context)
    }
    
    
    func pongHandler(_ metadata: NWProtocolWebSocket.Metadata) {
        metadata.setPongHandler(nwQueue) { [weak self] error in
            guard let strongSelf = self else { return }
            if let error = error {
                strongSelf.logger.error("Error: \(error.debugDescription)")
            }
        }
    }
    
    
    func send(data: Data?, context: NWConnection.ContentContext) async throws {
        try await sendAsync(data: data, context: context)
        receiveAndFeed()
    }
    
    
    func sendAsync(data: Data?, context: NWConnection.ContentContext) async throws -> Void {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
            connection?.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed({ error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }))
        })
    }
}

@available(macOS 10.15, iOS 14, tvOS 13, watchOS 6, *)
public final class WhiteTipped: NSObject {
    
    public var headers: [String: String]?
    public var urlRequest: URLRequest?
    public var cookies: [HTTPCookie]
    private var canRun: Bool = true
    private var connection: NWConnection?
    private var parameters: NWParameters?
    private var endpoint: NWEndpoint?
    let logger: Logger = Logger(subsystem: "WhiteTipped", category: "NWConnection")
    weak var receiver: WhiteTippedRecieverProtocol?
    var nwQueue = DispatchQueue(label: "WTS")
    let connectionState = NWConnectionState()
    var pingInterval: TimeInterval = 1.0
    var connectionTimeout: Int = 7
    
    public func setDelegate(_ conformer: WhiteTippedRecieverProtocol) {
        self.receiver = conformer
    }
    
    public init(
        headers: [String: String]?,
        urlRequest: URLRequest?,
        cookies: [HTTPCookie],
        pingInterval: TimeInterval,
        connectionTimeout: Int
    ) {
        self.headers = headers
        self.urlRequest = urlRequest
        self.cookies = cookies
        self.pingInterval = pingInterval
        self.connectionTimeout = connectionTimeout
    }
    
    deinit {}
    
    public func connect(url: URL, trustAll: Bool, certificates: [String]?) {
        canRun = true
        endpoint = .url(url)
        
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        //Limit Message size to 16MB to prevent abuse
        options.maximumMessageSize = 1_000_000 * 16
        
        if urlRequest != nil {
            options.setAdditionalHeaders(urlRequest?.allHTTPHeaderFields?.map { ($0.key, $0.value) } ?? [])
            _ = self.cookies.map { cookie in
                options.setAdditionalHeaders([(name: cookie.name, value: cookie.value)])
            }
        }
        if headers != nil {
            options.setAdditionalHeaders(headers?.map { ($0.key, $0.value) } ?? [])
        }
        if trustAll {
            do  {
                parameters = try TLSConfiguration.trustSelfSigned(nwQueue, certificates: certificates, logger: logger)
            } catch {
                fatalError(error.localizedDescription)
            }
        } else {
            parameters = (url.scheme == "ws" ? .tcp : .tls)
        }
        
        parameters?.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        
        guard let endpoint = endpoint else { return }
        guard let parameters = parameters else { return }
        connection = NWConnection(to: endpoint, using: parameters)
        connection?.start(queue: nwQueue)
        
        pathHandlers()
        monitorConnection()
    }
    
    
    private func pathHandlers() {
        connection?.stateUpdateHandler = { [weak self] state in
            guard let strongSelf = self else {return}
            strongSelf.connectionState.currentState(state)
        }
        
        connection?.betterPathUpdateHandler = { [weak self] value in
            guard let strongSelf = self else { return }
            strongSelf.connectionState.betterPath(value)
            strongSelf.receiver?.received(.betterPath, packet: MessagePacket(betterPath: value))
        }
        
        connection?.viabilityUpdateHandler = { [weak self] value in
            guard let strongSelf = self else {return}
            strongSelf.connectionState.viablePath(value)
            strongSelf.receiver?.received(.viablePath, packet: MessagePacket(viablePath: value))
        }
    }
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    
    private func receiveAndFeed() {
        connection?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
            let listener = ListenerStruct(data: completeContent, context: contentContext, isComplete: isComplete)
            self.channelRead(listener)
            if error == nil {
                self.receiveAndFeed()
            }
        })
    }
    
    
    private func channelRead(_ listener: ListenerStruct) {
        guard let metadata = listener.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
        switch metadata.opcode {
        case .cont:
            logger.trace("Received continuous WebSocketFrame")
            return
        case .text:
            logger.trace("Received text WebSocketFrame")
            guard let data = listener.data else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            receiver?.received(.text, packet: MessagePacket(text: text))
            return
        case .binary:
            logger.trace("Received binary WebSocketFrame")
            guard let data = listener.data else { return }
            receiver?.received(.binary, packet: MessagePacket(binary: data))
            return
        case .close:
            logger.trace("Received close WebSocketFrame")
            connection?.cancel()
            notifyDisconnection(.protocolCode(.goingAway))
            return
        case .ping:
            logger.trace("Received ping WebSocketFrame")
            return
        case .pong:
            logger.trace("Received pong WebSocketFrame")
            do {
                try ping(interval: 3)
            } catch {
                logger.error("\(error)")
            }
            return
        @unknown default:
            fatalError("Unkown State Case")
        }
    }
    
    
    public func disconnect(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) throws {
        canRun = false
        if code == .protocolCode(.normalClosure) {
            connection?.cancel()
            notifyDisconnection(code)
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            notifyDisconnection(code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            try send(data: nil, context: context)
        }
    }
    
    
    func notifyDisconnection(with error: NWError? = nil, _ reason: NWProtocolWebSocket.CloseCode) {
        let result = DisconnectResult(error: error, code: reason)
        receiver?.received(.disconnectPacket, packet: MessagePacket(disconnectPacket: result))
    }
    
    
    public func onCurrentState(_ callback: @escaping (NWConnection.State) -> ()) {
        self.connectionState.currentState = callback
    }
    
    public func onBetterPath(_ callback: @escaping (Bool) -> ()) {
        self.connectionState.betterPath = callback
    }
    
    public func onViablePath(_ callback: @escaping (Bool) -> ()) {
        self.connectionState.viablePath = callback
    }
    
    public func onListenerState(_ callback: @escaping (NWListener.State) -> ()) {
        self.connectionState.listenerState = callback
    }
    
    public func onConnection(_ callback: @escaping (NWConnection) -> ()) {
        self.connectionState.connection = callback
    }
    
    private func monitorConnection() {
        onCurrentState { [weak self] state in
            guard let strongSelf = self else { return }
            switch state {
            case .setup:
                strongSelf.logger.trace("Connection setup")
            case .waiting(let status):
                strongSelf.logger.trace("Connection waiting with status - Status: \(status.localizedDescription)")
            case .preparing:
                strongSelf.logger.trace("Connection preparing")
                DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + .seconds(strongSelf.connectionTimeout)) { [weak self] in
                    guard let strongSelf = self else { return }
                    if strongSelf.connection?.state != .ready {
                        strongSelf.connection?.stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
                    }
                }
            case .ready:
                strongSelf.logger.trace("Connection established")
                strongSelf.onBetterPath { [weak self] betterPath in
                    guard let strongSelf = self else { return }
                    if betterPath {
                        strongSelf.logger.trace("We found a better path")
                        strongSelf.connection = nil
                        guard let endpoint = strongSelf.endpoint else { return }
                        guard let parameters = strongSelf.parameters else { return }
                        let newConnection = NWConnection(to: endpoint, using: parameters)
                        newConnection.start(queue: strongSelf.nwQueue)
                        strongSelf.pathHandlers()
                        strongSelf.connection = newConnection
                        strongSelf.connectionState.connection(newConnection)
                    }
                }
                strongSelf.receiveAndFeed()
                DispatchQueue.main.async { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.receiver?.received(.connectionStatus, packet: MessagePacket(connectionStatus: true))
                }
            case .failed(let error):
                strongSelf.logger.trace("Connection failed with error - Error: \(error.localizedDescription)")
                strongSelf.connection?.cancel()
                strongSelf.notifyDisconnection(with: error, .protocolCode(.abnormalClosure))
                strongSelf.receiver?.received(.connectionStatus, packet: MessagePacket(connectionStatus: false))
            case .cancelled:
                strongSelf.logger.trace("Connection cancelled")
                strongSelf.notifyDisconnection(.protocolCode(.normalClosure))
                DispatchQueue.main.async { [weak self] in
                    guard let strongSelf = self else { return }
                    strongSelf.receiver?.received(.connectionStatus, packet: MessagePacket(connectionStatus: false))
                }
            default:
                strongSelf.logger.trace("Connection default")
                return
            }
        }
    }
    
    public func sendText(_ text: String) throws {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try send(data: data, context: context)
    }
    
    
    public func sendBinary(_ data: Data) throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try send(data: data, context: context)
    }
    
    public func ping(interval: TimeInterval) throws {
        DispatchQueue.global(qos: .background).asyncAfter(deadline:  .now() + interval) { [weak self] in
            guard let strongSelf = self else { return }
            do {
                try strongSelf.sendPing()
            } catch {
                strongSelf.logger.error("\(error.localizedDescription)")
            }
        }
    }
    
    
    func sendPing() throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        pongHandler(metadata)
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [metadata]
        )
        try send(data: "ping".data(using: .utf8), context: context)
    }
    
    
    func pongHandler(_ metadata: NWProtocolWebSocket.Metadata) {
        metadata.setPongHandler(nwQueue) { [weak self] error in
            guard let strongSelf = self else { return }
            if let error = error {
                strongSelf.logger.error("Error: \(error.debugDescription)")
            }
        }
    }
    
    
    func send(data: Data?, context: NWConnection.ContentContext) throws {
        connection?.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed({ [weak self] error in
                guard let strongSelf = self else { return }
                if let error = error {
                    strongSelf.logger.error("\(error.localizedDescription)")
                }
            }))
        receiveAndFeed()
    }
}
#endif
