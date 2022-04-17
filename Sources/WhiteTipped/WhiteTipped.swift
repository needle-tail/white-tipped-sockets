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
        connection?.start(queue: .global())
        do {
        try await channelRead()
        } catch {
            print(error)
        }
        await monitorConnection()
    }
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    private func channelRead() async throws {
        let result = try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Listener, Error>) in
            connection?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    guard let contentContext = contentContext else { return }
                    guard let completeContent = completeContent else { return }
                    continuation.resume(returning: Listener(data: completeContent, context: contentContext))
                }
            })
        })
        
        guard let metadata = result.context.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
        
        switch metadata.opcode {
        case .cont:
            break
        case .text:
            //We want to ensure order asynchronously, so we queue our frames in a sequence
            await consumer.feedConsumer([result.data])
            
            for try await result in ListenerSequence(consumer: consumer) {
                switch result {
                case .success(let text):
                    recievedText = String(data: text, encoding: .utf8)
                case .retry:
                    break
                case .finished:
                    return
                }
            }
            
        case .binary:
            //We want to ensure order asynchronously, so we queue our frames in a sequence
            await consumer.feedConsumer([result.data])
            
            for try await result in ListenerSequence(consumer: consumer) {
                switch result {
                case .success(let data):
                    recievedBinary = data
                case .retry:
                    break
                case .finished:
                    return
                }
            }
        case .close:
            //TODO: Write close logic
            break
        case .ping:
            //Auto Reply
            break
        case .pong:
            await ping(interval: 100*60)
        @unknown default:
            fatalError()
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
        let state = await asyncMonitorConnection()
        switch state {
        case .setup:
            logger.info("Connection setup")
        case .waiting(let status):
            logger.info("Connection waiting with status - Status: \(status.localizedDescription)")
        case .preparing:
            logger.info("Connection preparing")
        case .ready:
            logger.info("Connection established")
            
            //TODO: Setup app
        case .failed(let error):
            logger.info("Connection failed with error - Error: \(error.localizedDescription)")
            connection?.cancel()
            
            //TODO: Notify app that the connection failed
        case .cancelled:
            logger.info("Connection cancelled")
        default:
            break
        }
        
        connection?.start(queue: DispatchQueue(label: "WhiteTipped"))
        
        do {
            let content = try await receiveOnConnection()
            logger.info("received Data on connection - Data: \(String(content.count))")
            //TODO: Notify App Data recieved
        } catch {
            print(error)
        }
    }
    
    private func asyncMonitorConnection() async -> NWConnection.State {
        return await withCheckedContinuation { (continuation: CheckedContinuation<NWConnection.State, Never>) in
            connection?.stateUpdateHandler = { state in
                continuation.resume(returning: state)
            }
        }
    }
    
    private func receiveOnConnection() async throws -> Data {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Data, Error>) in
            connection?.receive(minimumIncompleteLength: 1, maximumLength: 437358) { content, contentContext, isComplete, error in
                if let content = content {
                    continuation.resume(returning: content)
                } else {
                    continuation.resume(throwing: error!)
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
    
    
    func sendText(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        await send(data: data, context: context)
    }
    
    func sendBinary(_ data: Data) async {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        await send(data: data, context: context)
    }
    
    private func ping(interval: TimeInterval) async {
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
                guard let metadata = context.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
                guard (metadata.opcode == .close) else { return }
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
