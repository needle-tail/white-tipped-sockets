import Foundation
import Network
import OSLog

public final class WhiteTipped {
    
    
   public var recievedText: String?
   public var recievedBinary: Data?
   public var receviedPong: Data?
    
    public var headers: [String: String]?
    public var urlRequest: URLRequest?
    public var cookies: HTTPCookie
    
    private var connection: NWConnection?
    private var parameters: NWParameters?
    private var endpoint: NWEndpoint?
    private var logger: Logger
    private var consumer = ListenerConsumer()
    

    
    public init(
        headers: [String: String]?,
        urlRequest: URLRequest?,
        cookies: HTTPCookie
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
        await monitorConnection()
    }
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    private func listen() async throws {
        
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
            //TODO: Write pong logic
        break
        @unknown default:
            fatalError()
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
    
    
    
    public func disconnect() {
        
    }
    
    
    func sendText() {
        
        
    }
    
    func sendBinary() {
        
    }
    
    func sendPing() {
        
    }
    
    
}
