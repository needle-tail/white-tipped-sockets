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
public final actor WhiteTippedListener {
    
    public struct NetworkConfiguration: @unchecked Sendable {
        let headers: [String: String]
        let cookies: [HTTPCookie]
        var urlRequest: URLRequest?
        let pingPongInterval: TimeInterval
        let certificates: [String]
        let maximumMessageSize: Int
        let autoReplyPing: Bool
        let wtAutoReplyPing: Bool
        let queue: DispatchQueue
        let lock = NSLock()
        
        public init(
            queue: String,
            headers: [String : String] = [:],
            cookies: [HTTPCookie] = [],
            urlRequest: URLRequest? = nil,
            pingPongInterval: TimeInterval = 1.0,
            certificates: [String] = [],
            maximumMessageSize: Int = 1_000_000 * 16,
            autoReplyPing: Bool = false,
            wtAutoReplyPing: Bool = false
        ) {
            lock.lock()
            self.queue = DispatchQueue(label: queue, attributes: .concurrent)
            lock.unlock()
            self.headers = headers
            self.cookies = cookies
            self.urlRequest = urlRequest
            self.pingPongInterval = pingPongInterval
            self.certificates = certificates
            self.maximumMessageSize = maximumMessageSize
            self.autoReplyPing = autoReplyPing
            self.wtAutoReplyPing = wtAutoReplyPing
        }
    }
    
    private var canRun: Bool = true
    private var parameters: NWParameters?
    private var endpoint: NWEndpoint?
    internal var listener: NWListener
    
    public var configuration: NetworkConfiguration
    let logger: Logger = Logger(subsystem: "WhiteTipped", category: "NWConnection")
    
    public init(
        configuration: NetworkConfiguration
    ) async throws {
        self.configuration = configuration
        
        let parameters = try TLSConfiguration.trustSelfSigned(configuration.queue, certificates: configuration.certificates)
        
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        //Limit Message size to 16MB to prevent abuse
        options.maximumMessageSize = 1_000_000 * 16
        
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        
        self.listener = try NWListener(using: parameters, on: 8080)
        self.listener.service = NWListener.Service(
            name: "WTServer",
            type: "server.ws",
            domain: "needletails.com",
            txtRecord: nil
        )
    }
    
    
    let connectionState = ObservableNWConnectionState()
    var stateCancellable: Cancellable?
    var connectionCancellable: Cancellable?
    
    
    public func listen() async {
        listener.cancel()
        canRun = true
        do {
            pathHandlers()
            try await monitorConnection(listener)
            listener.start(queue: configuration.queue)
        } catch {
            fatalError("Unable to start WebSocket server on port \(8080)")
        }
    }
    
    private func pathHandlers() {
        stateCancellable = connectionState.publisher(for: \.currentState) as? Cancellable
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.connectionState.listenerState = state
        }
        
        connectionCancellable = connectionState.publisher(for: \.connection) as? Cancellable
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connectionState.connection = connection
        }
    }
    
    private func monitorConnection(_ listener: NWListener) async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self else { return }
                for await state in self.connectionState.$listenerState.values {
                    switch state {
                    case .setup:
                        logger.trace("Connection setup")
                    case .waiting(let error):
                        logger.trace("Connection waiting with status - Error: \(error.localizedDescription)")
                    case .ready:
                        logger.trace("Connection ready")
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            try Task.checkCancellation()
                            group.addTask { [weak self] in
                                guard let self else { return }
                                try await self.handleConnections(listener: listener)
                            }
                            _ = try await group.next()
                            group.addTask { [weak self] in
                                guard let self else { return }
                                try await asyncReceiverLoop(listener: listener)
                            }
                            _ = try await group.next()
                            group.cancelAll()
                        }
                    case .failed(let error):
                        logger.trace("Connection failed with error - Error: \(error.localizedDescription)")
                    case .cancelled:
                        logger.trace("Connection cancelled")
                    @unknown default:
                        fatalError("Unknown State")
                    }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    private func asyncReceiverLoop(listener: NWListener) async throws {
        while canRun {
            try await withThrowingTaskGroup(of: Void.self) { group in
                try Task.checkCancellation()
                group.addTask { [weak self] in
                    guard let self else { return }
                    for try await result in WhiteTippedAsyncSequence(consumer: consumer) {
                        switch result {
                        case .success(let session):
                            let listenerStruct = try await feedSession(session)
                            try await channelRead(listener: listenerStruct)
                        case .finished:
                            return
                        }
                    }
                }
                _ = try await group.next()
                group.cancelAll()
            }
        }
    }
    
    func feedSession(_ session: Published<NWConnection?>.Publisher.Output) async throws -> WhiteTippedMesssage {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<WhiteTippedMesssage, Error>) in
            session?.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
                if let error = error {
                    continuation.resume(throwing: error)
                }
                let listenerStruct = WhiteTippedMesssage(
                    data: completeContent,
                    context: contentContext,
                    isComplete: isComplete,
                    session: session
                )
                continuation.resume(returning: listenerStruct)
            })
        })
    }
    
    let consumer = WhiteTippedAsyncConsumer<Published<NWConnection?>.Publisher.Output>()
    
    private func handleConnections(listener: NWListener) async throws {
        for await session in connectionState.$connection.values {
            //STORE SESSIONS IN A ASYNC SEQUENCE and LOOP ON THEM
            await consumer.feedConsumer([session])
        }
    }
    
    
    private struct Listener {
        var data: Data
        var context: NWConnection.ContentContext
    }
    
    
    private func channelRead(listener: WhiteTippedMesssage) async throws {
        do {
            guard let metadata = listener.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
            switch metadata.opcode {
            case .cont:
                logger.trace("Received continuous WebSocketFrame")
            case .text:
                logger.trace("Received text WebSocketFrame")
                guard let data = listener.data else { return }
                guard let text = String(data: data, encoding: .utf8) else { return }
                guard let session = listener.session else { return }
                try await sendText(session, text: text)
            case .binary:
                logger.trace("Received binary WebSocketFrame")
                guard let data = listener.data else { return }
                guard let session = listener.session else { return }
                try await sendBinary(session, data: data)
            case .close:
                logger.trace("Received close WebSocketFrame")
                guard let session = listener.session else { return }
                try await disconnect(session)
                session.cancel()
            case .ping:
                logger.trace("Received ping WebSocketFrame")
                guard let session = listener.session else { return }
                try await sendPong(session)
            case .pong:
                logger.trace("Received pong WebSocketFrame")
                guard let session = listener.session else { return }
                try await sendPing(session)
            @unknown default:
                fatalError("Unkown State Case")
            }
        } catch {
            logger.error("\(error)")
        }
    }
    
    
    public func disconnect(_ session: NWConnection, code: NWProtocolWebSocket.CloseCode = .protocolCode(.normalClosure)) async throws {
        canRun = false
        if code == .protocolCode(.normalClosure) {
        } else {
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = code
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            guard let data = "close".data(using: .utf8) else { return }
            try await send(session, data: data, context: context)
        }
        
        stateCancellable = nil
        connectionCancellable = nil
        listener.cancel()
    }
    
    public func sendText(_ session: NWConnection, text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await send(session, data: data, context: context)
    }
    
    public func sendBinary(_ session: NWConnection, data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        try await send(session, data: data, context: context)
    }
    
    public func ping(_ session: NWConnection, autoLoop: Bool) async throws {
        if autoLoop {
            while try await suspendAndPing(session) {}
        } else {
            _ = try await suspendAndPing(session)
        }
        @Sendable func suspendAndPing(_ session: NWConnection) async throws -> Bool {
            try await sleepTask(configuration.pingPongInterval, performWork: {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.canRun {
                        try await self.sendPong(session)
                    }
                }
            })
            
            return await canRun
        }
    }
    
    public func pong(_ session: NWConnection, autoLoop: Bool) async throws {
        if autoLoop {
            while try await suspendAndPong(session) {}
        } else {
            _ = try await suspendAndPong(session)
        }
        @Sendable func suspendAndPong(_ session: NWConnection) async throws -> Bool {
            try await sleepTask(configuration.pingPongInterval, performWork: {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.canRun {
                        try await self.sendPong(session)
                    }
                }
            })
            
            return await canRun
        }
    }
    
    func sendPing(_ session: NWConnection) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        try await self.pongHandler(metadata)
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [metadata]
        )
        guard let data = "ping".data(using: .utf8) else { return }
        try await self.send(session, data: data, context: context)
    }
    
    func sendPong(_ session: NWConnection) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
        try await pongHandler(metadata)
        let context = NWConnection.ContentContext(
            identifier: "pong",
            metadata: [metadata]
        )
        guard let data = "pong".data(using: .utf8) else { return }
        try await send(session, data: data, context: context)
    }
    
    func pongHandler(_ metadata: NWProtocolWebSocket.Metadata) async throws {
        Task {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
                metadata.setPongHandler(configuration.queue) { error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            })
        }
    }
    
    func send(_ session: NWConnection, data: Data, context: NWConnection.ContentContext) async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask {
                try await self.sendAsync(session, data: data, context: context)
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    func sendAsync(_ session: NWConnection, data: Data, context: NWConnection.ContentContext) async throws -> Void {
        return try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
            session.send(
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
    
    func sleepTask(_ pingInterval: Double, performWork: @Sendable @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            try Task.checkCancellation()
            group.addTask {
                if #available(iOS 16.0, macOS 13, *) {
                    try await Task.sleep(until: .now + .seconds(pingInterval), clock: .suspending)
                } else {
                    try await Task.sleep(nanoseconds: NSEC_PER_SEC * UInt64(pingInterval))
                }
                try await performWork()
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
#endif
