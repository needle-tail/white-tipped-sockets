import Foundation
import Network
import OSLog
import Combine

public final actor WhiteTipped {
    
    public var headers: [String: String]?
    public var urlRequest: URLRequest?
    public var cookies: HTTPCookie?
    private var canRun: Bool = true
    private var connection: NWConnection?
    private var parameters: NWParameters?
    private var endpoint: NWEndpoint?
    let logger: Logger
    private var consumer = ListenerConsumer()
    @MainActor public var receiver = WhiteTippedReciever()
    
    
    public init(
        headers: [String: String]?,
        urlRequest: URLRequest?,
        cookies: HTTPCookie?
    ) async {
        self.headers = headers
        self.urlRequest = urlRequest
        self.cookies = cookies
        logger = Logger(subsystem: "WhiteTipped", category: "NWConnection")
    }
    
    
    var nwQueue = DispatchQueue(label: "WTK")
    let connectionState = NWConnectionState()
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
        }
        if headers != nil {
            options.setAdditionalHeaders(headers?.map { ($0.key, $0.value) } ?? [])
        }
        if trustAll {
            parameters = try? trustSelfSigned(nwQueue, certificates: certificates)
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
            guard let strongSelf = self else {return}
            strongSelf.connectionState.currentState = state
        }

        betterPathCancellable = connectionState.publisher(for: \.betterPath) as? Cancellable
        connection?.betterPathUpdateHandler = { [weak self] value in
            guard let strongSelf = self else {return}
            strongSelf.connectionState.betterPath = value
        }

        viablePatheCancellable = connectionState.publisher(for: \.viablePath) as? Cancellable
        connection?.viabilityUpdateHandler = { [weak self] value in
            guard let strongSelf = self else {return}
            strongSelf.connectionState.viablePath = value
        }
    }
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    
    private func receiveAndFeed() throws {
        connection?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
            let listener = ListenerStruct(data: completeContent, context: contentContext, isComplete: isComplete)
            self.consumer.feedConsumer(listener)
            Task {
                if !self.consumer.queue.isEmpty {
                    try await self.channelRead()
                }
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
                        return
                    case .text:
                        logger.trace("Received text WebSocketFrame")
                        guard let data = listener.data else { return }
                        guard let text = String(data: data, encoding: .utf8) else { return }
                        await MainActor.run {
                            receiver.textReceived.send(text)
                        }
                        return
                    case .binary:
                        logger.trace("Received binary WebSocketFrame")
                        guard let data = listener.data else { return }
                        await MainActor.run {
                            receiver.binaryReceived.send(data)
                        }
                        return
                    case .close:
                        logger.trace("Received close WebSocketFrame")
                        connection?.cancel()
                        await notifyDisconnection(.protocolCode(.goingAway))
                        return
                    case .ping:
                        logger.trace("Received ping WebSocketFrame")
                        return
                    case .pong:
                        logger.trace("Received pong WebSocketFrame")
                        return
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
    
    
    public func disconnect(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) async {
        canRun = false
        if code == .protocolCode(.normalClosure) {
            connection?.cancel()
            await notifyDisconnection(code)
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            await notifyDisconnection(code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            await send(data: nil, context: context)
        }
        
        stateCancellable = nil
        betterPathCancellable = nil
        viablePatheCancellable = nil
    }
    
    
    func notifyDisconnection(with error: NWError? = nil, _ reason: NWProtocolWebSocket.CloseCode) async {
        let result = DisconnectResult(error: error, code: reason)
        await MainActor.run {
            receiver.disconnectionPacketReceived.send(result)
        }
    }
    
    
    private func monitorConnection(_ betterPath: Bool = false) async  {
        do {
            //AsyncPublish prevents currentState from finishing the suspension
            for await state in connectionState.$currentState.values {
                switch state {
                case .setup:
                    logger.trace("Connection setup")
                case .waiting(let status):
                    logger.trace("Connection waiting with status - Status: \(status.localizedDescription)")
                case .preparing:
                    logger.trace("Connection preparing")
                case .ready:
                    logger.trace("Connection established")
                    print(betterPath)
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
                    try receiveAndFeed()
                    await MainActor.run {
                        receiver.connectionStatus.send(true)
                    }
                case .failed(let error):
                    logger.trace("Connection failed with error - Error: \(error.localizedDescription)")
                    connection?.cancel()
                    await notifyDisconnection(with: error, .protocolCode(.abnormalClosure))
                    await MainActor.run {
                        receiver.connectionStatus.send(false)
                    }
                case .cancelled:
                    logger.trace("Connection cancelled")
                    await notifyDisconnection(.protocolCode(.normalClosure))
                    await MainActor.run {
                        receiver.connectionStatus.send(false)
                    }
                default:
                    logger.trace("Connection default")
                    return
                }
                
                guard state != .setup, state != .preparing else { break }
            }
        } catch {
            logger.error("State Error: \(error.localizedDescription)")
        }
    }
    
    
    private func betterPath() async {
        for await result in connectionState.$betterPath.values {
            await MainActor.run {
                receiver.betterPathReceived.send(result)
            }
            break
        }
    }
    
    
    private func viablePath() async {
        for await result in connectionState.$viablePath.values {
            await MainActor.run {
                receiver.viablePathReceived.send(result)
            }
            break
        }
    }
    
    
    public func sendText(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        await send(data: data, context: context)
    }
    
    
    public func sendBinary(_ data: Data) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        await send(data: data, context: context)
    }
    
    public func ping(interval: TimeInterval) async {
        let date = RunLoop.timeInterval(interval)
        repeat {
            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
            if canRun {
            await sendPing()
            }
        } while await RunLoop.execute(date, canRun: canRun)
    }
    
    
    func sendPing() async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        pongHandler(metadata)
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [metadata]
        )
        await send(data: "ping".data(using: .utf8), context: context)
    }
    
    
    func pongHandler(_ metadata: NWProtocolWebSocket.Metadata) {
        metadata.setPongHandler(nwQueue) { [weak self] error in
            guard let strongSelf = self else { return }
            if let error = error {
                strongSelf.logger.error("Error: \(error.debugDescription)")
            }
        }
    }
    
    
    func send(data: Data?, context: NWConnection.ContentContext) async {
        do {
            try await sendAsync(data: data, context: context)
            try receiveAndFeed()
        } catch {
            logger.error("Send Data Error: \(error.localizedDescription)")
        }
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
