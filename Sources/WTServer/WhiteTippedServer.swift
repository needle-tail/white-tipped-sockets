//
//  WhiteTippedServer.swift
//  
//
//  Created by Cole M on 6/20/22.
//

#if canImport(Network)
import Foundation
import Network
import OSLog
import Combine
import WTHelpers

@available(iOS 15, macOS 12, *)
public final actor WhiteTippedServer {
    
    public var headers: [String: String]?
    public var urlRequest: URLRequest?
    public var cookies: HTTPCookie?
    private var canRun: Bool = true
    private var listener: NWListener?
    private var parameters: NWParameters?
    private var endpoint: NWEndpoint?

    let logger: Logger = Logger(subsystem: "WhiteTipped", category: "NWConnection")
//    private var consumer = ListenerConsumer()
    //    @MainActor public var receiver = WhiteTippedReciever()
    
    
    public init(
        headers: [String: String]?,
        urlRequest: URLRequest?,
        cookies: HTTPCookie?
    ) async {
        self.headers = headers
        self.urlRequest = urlRequest
        self.cookies = cookies
    }
    
    
    var nwQueue = DispatchQueue(label: "WTK")
    let connectionState = ObservableNWConnectionState()
    var stateCancellable: Cancellable?
    var connectionCancellable: Cancellable?
    
    
    public func listen() async {
        canRun = true
        do {
            let parameters = try TLSConfiguration.trustSelfSigned(nwQueue, certificates: nil)
            
            let options = NWProtocolWebSocket.Options()
            options.autoReplyPing = true
            //Limit Message size to 16MB to prevent abuse
            options.maximumMessageSize = 1_000_000 * 16
            
            parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
            
            listener = try NWListener(using: parameters, on: 8080)
            listener?.service = NWListener.Service(
                name: "WTServer",
                type: "server.ws",
                domain: "needletails.com",
                txtRecord: nil)
            
            await pathHandlers()
            await monitorConnection()
            await handleConnections()
            listener?.start(queue: nwQueue)
        } catch {
            fatalError("Unable to start WebSocket server on port \(8080)")
        }
    }
    
    
    private func pathHandlers() async {
        stateCancellable = connectionState.publisher(for: \.listenerState) as? Cancellable
        listener?.stateUpdateHandler = { [weak self] state in
            guard let strongSelf = self else {return}
            strongSelf.connectionState.listenerState = state
        }
        
        connectionCancellable = connectionState.publisher(for: \.connection) as? Cancellable
        listener?.newConnectionHandler = { [weak self] connection in
            //            print(connection)
            guard let strongSelf = self else {return}
            strongSelf.connectionState.connection = connection
        }
    }
    
    private func monitorConnection() async  {
        for await state in connectionState.$listenerState.values {
            switch state {
            case .setup:
                if #available(iOS 14, *) {
                    logger.trace("Connection setup")
                } else {
                    print("Connection setup")
                }
            case .waiting(let error):
                if #available(iOS 14, *) {
                    logger.trace("Connection waiting with status - Error: \(error.localizedDescription)")
                } else {
                    print("Connection waiting with status - Error: \(error.localizedDescription)")
                }
            case .ready:
                if #available(iOS 14, *) {
                    logger.trace("Connection ready")
                } else {
                    print("Connection ready")
                }
            case .failed(let error):
                if #available(iOS 14, *) {
                    logger.trace("Connection failed with error - Error: \(error.localizedDescription)")
                } else {
                    print("Connection failed with error - Error: \(error.localizedDescription)")
                }
            case .cancelled:
                if #available(iOS 14, *) {
                    logger.trace("Connection cancelled")
                } else {
                    print("Connection cancelled")
                }
            @unknown default:
                break
            }
            break
        }
        
    }
    
    private func handleConnections() async {
        for await session in connectionState.$connection.values {
            session?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
                let listener = ListenerStruct(
                    data: completeContent,
                    context: contentContext,
                    isComplete: isComplete,
                    session: session
                )
//                self.consumer.feedConsumer(listener)
                //                Task {
                //                    if !self.consumer.queue.isEmpty {
                //                        try await self.channelRead()
                //                    }
                //                }
            })
            break
        }
    }
    
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    
    private func channelRead() async throws {
//        do {
//            for try await result in ListenerSequence(consumer: consumer) {
//                switch result {
//                case .success(let listener):
//                    guard let metadata = listener.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
//                    switch metadata.opcode {
//                    case .cont:
//                        if #available(iOS 14, *) {
//                            logger.trace("Received continuous WebSocketFrame")
//                        } else {
//                            print("Received continuous WebSocketFrame")
//                        }
//                        return
//                    case .text:
//                        if #available(iOS 14, *) {
//                            logger.trace("Received text WebSocketFrame")
//                        } else {
//                            print("Received text WebSocketFrame")
//                        }
//                        guard let data = listener.data else { return }
//                        guard let text = String(data: data, encoding: .utf8) else { return }
//                        guard let session = listener.session else { return }
//                        try await sendText(session, text: text)
//                        return
//                    case .binary:
//                        if #available(iOS 14, *) {
//                            logger.trace("Received binary WebSocketFrame")
//                        } else {
//                            print("Received binary WebSocketFrame")
//                        }
//                        guard let data = listener.data else { return }
//                        guard let session = listener.session else { return }
//                        try await sendBinary(session, data: data)
//                        return
//                    case .close:
//                        if #available(iOS 14, *) {
//                            logger.trace("Received close WebSocketFrame")
//                        } else {
//                            print("Received close WebSocketFrame")
//                        }
//                        return
//                    case .ping:
//                        if #available(iOS 14, *) {
//                            logger.trace("Received ping WebSocketFrame")
//                        } else {
//                            print("Received ping WebSocketFrame")
//                        }
//                        guard let session = listener.session else { return }
//                        try await sendPong(session)
//                        return
//                    case .pong:
//                        if #available(iOS 14, *) {
//                            logger.trace("Received pong WebSocketFrame")
//                        } else {
//                            print("Received pong WebSocketFrame")
//                        }
//                        return
//                    @unknown default:
//                        fatalError("Unkown State Case")
//                    }
//                case .finished:
//                    if #available(iOS 14, *) {
//                        logger.trace("Finished")
//                    } else {
//                        print("Finished")
//                    }
//                    return
//                case .retry:
//                    if #available(iOS 14, *) {
//                        logger.trace("Will retry")
//                    } else {
//                        print("Will retry")
//                    }
//                    return
//                }
//                
//            }
//        } catch {
//            if #available(iOS 14, *) {
//                logger.error("\(error.localizedDescription)")
//            } else {
//                print("\(error.localizedDescription)")
//            }
//        }
    }
    
    
    public func disconnect(code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) async {
        canRun = false
        if code == .protocolCode(.normalClosure) {
            listener?.cancel()
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            //            await send(session: , data: nil, context: context)
        }
        
        stateCancellable = nil
        connectionCancellable = nil
    }
    
    
    
    public func sendText(_ session: NWConnection, text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await sendAsync(session: session, data: data, context: context)
    }
    
    
    public func sendBinary(_ session: NWConnection, data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await sendAsync(session: session, data: data, context: context)
    }
    
    
    func sendPong(_ session: NWConnection) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        let context = NWConnection.ContentContext(
            identifier: "pong",
            metadata: [metadata]
        )
        try await sendAsync(session: session, data: "pong".data(using: .utf8), context: context)
    }
    
    func sendAsync(session: NWConnection, data: Data?, context: NWConnection.ContentContext) async throws -> Void {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
            session.send(
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
#endif
