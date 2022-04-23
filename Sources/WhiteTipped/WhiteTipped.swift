import Foundation
import Network
import OSLog

public final class WhiteTipped {
    
    
    public var recievedText: String?
    public var recievedBinary: Data?
    public var receviedPong: Data?
    
    public var headers: [String: String]?
    public var urlRequest: URLRequest?
    public var cookies: HTTPCookie?
    
    private var connection: NWConnection?
    private var parameters: NWParameters?
    private var endpoint: NWEndpoint?
    private var logger: Logger
    private var consumer = ListenerConsumer()
    private var stateConsumer = StateConsumer()
    
    
    public init(
        headers: [String: String]?,
        urlRequest: URLRequest?,
        cookies: HTTPCookie?
    ) {
        self.headers = headers
        self.urlRequest = urlRequest
        self.cookies = cookies
        logger = Logger(subsystem: "WhiteTipped", category: "NWConnection")
    }
    
    
    
    public func connect(url: URL) async {
        
        endpoint = .url(url)
        parameters = url.scheme == "ws" ? .tcp : .tls
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 1_000_000 * 16
        
        if urlRequest != nil {
            options.setAdditionalHeaders(urlRequest?.allHTTPHeaderFields?.map { ($0.key, $0.value) } ?? [])
        }
        if headers != nil {
            options.setAdditionalHeaders(headers?.map { ($0.key, $0.value) } ?? [])
        }
        parameters?.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        guard let endpoint = endpoint else { return }
        guard let parameters = parameters else { return }
        
        connection = NWConnection(to: endpoint, using: parameters)
        connection?.start(queue: DispatchQueue(label: "WTK"))
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let strongSelf = self else {return}
            strongSelf.stateConsumer.queue.enqueue(state)
        }
        
        await monitorConnection()
    }
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    
    private func receiveAndFeed() throws {
        connection?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
            let listener = ListenerStruct(data: completeContent, context: contentContext, isComplete: isComplete)
            self.consumer.feedConsumer(listener)
        })
        
        Task {
           try await channelRead()
        }
    }
    
    private func channelRead() async throws {
        do {
            for try await result in ListenerSequence(consumer: consumer) {
                
                switch result {
                case .success(let listener):
                    guard let metadata = listener.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
                    
                    switch metadata.opcode {
                    case .cont:
                        return
                    case .text:
                        guard let data = listener.data else { return }
                        recievedText = String(data: data, encoding: .utf8)
                    case .binary:
                        guard let data = listener.data else { return }
                        recievedBinary = data
                    case .close:
                        //TODO: Write close logic
                        return
                    case .ping:
                        //Auto Reply
                        return
                    case .pong:
                        await ping(interval: 100*60)
                    @unknown default:
                        fatalError()
                    }
                case .finished:
                    return
                case .retry:
                    return
                }
                
            }
        } catch {
            logger.error("\(error.localizedDescription)")
        }
    }
    
    
    public func disconnect(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) async {
        if code == .protocolCode(.normalClosure) {
            connection?.cancel()
            //report closing
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            await send(data: nil, context: context)
        }
    }
    
    private func monitorConnection() async  {
        do {
            for try await result in StateSequence(consumer: stateConsumer) {
                switch result {
                case .succes(let state):
                    switch state {
                    case .setup:
                        logger.info("Connection setup")
                    case .waiting(let status):
                        logger.info("Connection waiting with status - Status: \(status.localizedDescription)")
                    case .preparing:
                        logger.info("Connection preparing")
                    case .ready:
                        logger.info("Connection established")
                        try receiveAndFeed()
                    case .failed(let error):
                        logger.info("Connection failed with error - Error: \(error.localizedDescription)")
                        connection?.cancel()
                        
                        //TODO: Notify app that the connection failed
                    case .cancelled:
                        logger.info("Connection cancelled")
                    default:
                       return
                    }
                case .fail:
                    //Tear Down
                   return
                }
            }
            guard let content = try await receiveOnConnection() else { return }
            logger.info("received Data on connection - Data: \(String(content.count))")
        } catch {
            print(error)
        }
    }

    
    private func receiveOnConnection() async throws -> Data? {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Data?, Error>) in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 437358) { content, contentContext, isComplete, error in
                if let error = error {
                    
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: content)
                }
            }
        })
    }
    
    private func sendOnConnection(_ data: Data) async throws -> Void {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
            connection?.send(content: data, completion: .contentProcessed({ error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }))
        })
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
        while await RunLoop.execute(date, canRun: true) {
            await sendPing()
            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
        }
    }
    
    func sendPing() async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        do {
            try await pongHandler(metadata)
            let context = NWConnection.ContentContext(
                identifier: "ping",
                metadata: [metadata]
            )
            await send(data: "ping".data(using: .utf8), context: context)
        } catch {
            print(error)
        }
    }
    
    func pongHandler(_ metadata: NWProtocolWebSocket.Metadata) async throws -> Void{
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
            metadata.setPongHandler(.global()) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        })
    }
    
    
    func send(data: Data?, context: NWConnection.ContentContext) async {
        do {
            try await sendAsync(data: data, context: context)
//            guard let metadata = context.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
//            guard (metadata.opcode == .close) else { return }
            //TODO: Notify websocket closed
            
        } catch {
            print(error)
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
