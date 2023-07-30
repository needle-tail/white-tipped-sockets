
#if canImport(Network) && canImport(Combine)
import Foundation
import Network
import OSLog
import Combine
import WTHelpers

@available(iOS 13, macOS 12, *)
public final actor WhiteTippedConnection {
    
    public struct NetworkConfiguration: @unchecked Sendable {
        let headers: [String: String]
        let cookies: [HTTPCookie]
        var urlRequest: URLRequest?
        let pingPongInterval: TimeInterval
        let connectionTimeout: Int
        let url: URL
        let trustAll: Bool
        let certificates: [String]
        let maximumMessageSize: Int
        let autoReplyPing: Bool
        let wtAutoReplyPing: Bool
        let queue: DispatchQueue
        let loggerCategory: String
        let loggerSubSystem: String
        
        public init(
            queue: String,
            headers: [String : String] = [:],
            cookies: [HTTPCookie] = [],
            urlRequest: URLRequest? = nil,
            pingPongInterval: TimeInterval = 1.0,
            connectionTimeout: Int = 7,
            url: URL,
            trustAll: Bool,
            certificates: [String] = [],
            maximumMessageSize: Int = 1_000_000 * 16,
            autoReplyPing: Bool = false,
            wtAutoReplyPing: Bool = false,
            loggerSubSystem: String = "WhiteTipped",
            loggerCategory: String = "WhiteTippedConnection"
        ) {
            self.queue = DispatchQueue(label: queue, attributes: .concurrent)
            self.headers = headers
            self.cookies = cookies
            self.urlRequest = urlRequest
            self.pingPongInterval = pingPongInterval
            self.connectionTimeout = connectionTimeout
            self.url = url
            self.trustAll = trustAll
            self.certificates = certificates
            self.maximumMessageSize = maximumMessageSize
            self.autoReplyPing = autoReplyPing
            self.wtAutoReplyPing = wtAutoReplyPing
            self.loggerSubSystem = loggerSubSystem
            self.loggerCategory = loggerCategory
        }
    }
    
    @MainActor public var receiver: WhiteTippedReciever
    public var configuration: NetworkConfiguration
    private var canRun: Bool = false
    private var connection: NWConnection
    private let connectionState = ObservableNWConnectionState()
    private var stateCancellable: Cancellable?
    private var betterPathCancellable: Cancellable?
    private var viablePathCancellable: Cancellable?
    private var currentStateCancellable: Cancellable?
    private weak var receiverDelegate: WhiteTippedRecieverDelegate?
    private static let listernReceiver = ListenerReceiver()
    
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
        options.autoReplyPing = configuration.autoReplyPing
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
        
        let parameters: NWParameters = configuration.trustAll ? try TLSConfiguration.trustSelfSigned(
            configuration.trustAll,
            queue: configuration.queue,
            certificates: configuration.certificates) : (configuration.url.scheme == "ws" ? .tcp : .tls)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(configuration.url), using: parameters)
    }
    
    func createLogger() async {
        if #available(iOS 14, *) {
            self.logger = Logger(subsystem: configuration.loggerSubSystem, category: configuration.loggerCategory)
        } else {
            self.oslog = OSLog(subsystem: configuration.loggerSubSystem, category: configuration.loggerCategory)
        }
    }
    
    deinit {
        //        print("RECLAIMING MEMORY IN WTS")
    }
    
    public func connect() async {
        await self.createLogger()
        self.connection.start(queue: self.configuration.queue)
        do {
            if #available(iOS 15, *) {
                self.pathHandlers()
                try await withThrowingTaskGroup(of: Void.self, body: { group in
                    try Task.checkCancellation()
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.betterPath(self.connectionState)
                    }
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.viablePath(self.connectionState)
                    }
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.monitorConnection(self.connectionState)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                })
            } else {
                try await withThrowingTaskGroup(of: Void.self, body: { group in
                    try Task.checkCancellation()
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        try await self.setupViability(self.connection)
                    }
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        try await self.setupConnectionState(self.connection)
                    }
                    group.addTask { [weak self] in
                        guard let self = self else { return }
                        try await self.setupBetterPath(self.connection)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                })
            }
        } catch {
            if #available(iOS 14, *) {
                self.logger?.error("\(error.localizedDescription)")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("@%", log: oslog, type: .error, error.localizedDescription)
            }
        }
    }
    
    private func setupViability(_ connection: NWConnection) async throws {
        try await withThrowingTaskGroup(of: AsyncStream<Bool>?.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self = self else { return nil }
                return try await self.viabilityStream(connection)
            }
            guard let next = try await group.next() else { return }
            group.addTask { [weak self] in
                guard let self = self else { return nil }
                guard let stream = next else { return nil }
                try await self.viablePath(stream, connection: connection)
                return stream
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    private func setupConnectionState(_ connection: NWConnection) async throws {
        try await withThrowingTaskGroup(of: AsyncStream<NWConnection.State>?.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self = self else { return nil }
                return try await self.stateStream(connection)
            }
            guard let next = try await group.next() else { return }
            group.addTask { [weak self] in
                guard let self = self else { return nil }
                guard let stream = next else { return nil }
                try await self.connectionState(stream)
                return stream
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    private func setupBetterPath(_ connection: NWConnection) async throws {
        try await withThrowingTaskGroup(of: AsyncStream<Bool>?.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self = self else { return nil }
                return try await self.betterPathStream(connection)
            }
            guard let next = try await group.next() else { return }
            group.addTask { [weak self] in
                guard let self = self else { return nil }
                guard let stream = next else { return nil }
                try await self.betterPath(stream, connection: connection)
                return nil
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    //MARK: iOS 13,14 Handlers
    private func viabilityStream(_ connection: NWConnection) async throws -> AsyncStream<Bool>  {
        return AsyncStream { continuation in
            connection.viabilityUpdateHandler = { value in
                continuation.yield(value)
            }
        }
    }
    
    private func stateStream(_ connection: NWConnection) async throws -> AsyncStream<NWConnection.State> {
        return AsyncStream { continuation in
            connection.stateUpdateHandler = { state in
                continuation.yield(state)
            }
        }
    }
    
    private func betterPathStream(_ connection: NWConnection) async throws -> AsyncStream<Bool> {
        return AsyncStream { continuation in
            connection.betterPathUpdateHandler = { path in
                continuation.yield(path)
            }
        }
    }
    
    
    private func betterPath(_ stream: AsyncStream<Bool>, connection: NWConnection) async throws {
        for try await value in stream {
            guard await value != self.receiver.betterPathReceived && value else { return }
            try await self.receiverDelegate?.received(message: .betterPath(value))
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.receiver.betterPathReceived = value
            }
            
            if value {
                try await withThrowingTaskGroup(of: Void.self, body: { group in
                    try Task.checkCancellation()
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.setupConnectionState(connection)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                })
            }
        }
    }
    
    private func viablePath(_ stream: AsyncStream<Bool>, connection: NWConnection) async throws {
        for try await value in stream {
            guard await value != self.receiver.viablePathReceived else { return }
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.receiver.viablePathReceived = value
            }
            
            try await self.receiverDelegate?.received(message: .viablePath(value))
            
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.receiver.viablePathReceived = value
            }
            
            if value && self.connectionState.currentState != .ready {
                try await withThrowingTaskGroup(of: Void.self, body: { group in
                    try Task.checkCancellation()
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.setupConnectionState(connection)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                })
            }
        }
    }
    
    
    private func connectionState(_ stream: AsyncStream<NWConnection.State>) async throws {
        for try await state in stream {
            try await self.monitorConnectionLogic(
                state,
                betterPath: self.receiver.betterPathReceived,
                viablePath: self.receiver.viablePathReceived
            )
        }
    }
    
    @objc private func connectionTimeout() async {
        
    }
    
    //MARK: iOS 15 and up Handlers
    @available(iOS 15, *)
    private func pathHandlers() {
        self.stateCancellable = self.connectionState.publisher(for: \.currentState) as? Cancellable
        self.betterPathCancellable = self.connectionState.publisher(for: \.betterPath) as? Cancellable
        self.viablePathCancellable = self.connectionState.publisher(for: \.viablePath) as? Cancellable
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.connectionState.currentState = state
        }
        
        connection.betterPathUpdateHandler = { [weak self] value in
            guard let self else { return }
            self.connectionState.betterPath = value
        }
        
        connection.viabilityUpdateHandler = { [weak self] value in
            guard let self else { return }
            self.connectionState.viablePath = value
        }
    }
    
    @available(iOS 15, *)
    private func betterPath(_ connectionState: ObservableNWConnectionState) async throws {
        for await result in connectionState.$betterPath.values {
            try await self.receiverDelegate?.received(message: .betterPath(result))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.betterPathReceived = result
            }
            if result {
                try await withThrowingTaskGroup(of: Void.self, body: { group in
                    try Task.checkCancellation()
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.monitorConnection(connectionState)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                })
            }
        }
    }
    
    @available(iOS 15, *)
    private func viablePath(_ connectionState: ObservableNWConnectionState) async throws {
        for await result in connectionState.$viablePath.values {
            try await self.receiverDelegate?.received(message: .viablePath(result))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.viablePathReceived = result
            }
            
            if result && connectionState.currentState != .ready {
                try await withThrowingTaskGroup(of: Void.self, body: { group in
                    try Task.checkCancellation()
                    group.addTask { [weak self] in
                        guard let self else { return }
                        try await self.monitorConnection(connectionState)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                })
            }
        }
    }
    
    @available(iOS 15, *)
    private func monitorConnection(_ connectionState: ObservableNWConnectionState) async throws {
        for await state in connectionState.$currentState.values {
            try await self.monitorConnectionLogic(
                state,
                betterPath: self.receiver.betterPathReceived,
                viablePath: self.receiver.viablePathReceived
            )
        }
    }
    
    //MARK: Connection Logic
    private func monitorConnectionLogic(_
                                        state: NWConnection.State,
                                        betterPath: Bool,
                                        viablePath: Bool
    ) async throws {
        switch state {
        case .setup:
            if #available(iOS 14, *) {
                self.logger?.info("Connection setup")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Connection setup", log: oslog, type: .info)
            }
        case .waiting(let status):
            if #available(iOS 14, *) {
                self.logger?.info("Connection waiting with status - Status: \(status.localizedDescription)")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Connection waiting with status - Status:", log: oslog, type: .info)
            }
        case .preparing:
            if #available(iOS 14, *) {
                self.logger?.info("Connection preparing")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Connection preparing", log: oslog, type: .info)
            }
            if #available(iOS 16.0, macOS 13, *) {
                let clock = ContinuousClock()
                let time = clock.measure {
                    while self.connectionState.currentState != .ready { }
                }
                
                let state = self.connection.state != .ready
                if time.components.seconds >= Int64(self.configuration.connectionTimeout) && state {
                    self.connection.stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
                }
            } else {
                //I don't like this but it works for now
                Task {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        try Task.checkCancellation()
                        group.addTask {
                            try await Task.sleep(nanoseconds: NSEC_PER_SEC * UInt64(self.configuration.connectionTimeout))
                            if await self.connection.state != .ready {
                                await self.connection.stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                }
            }
        case .ready:
            if #available(iOS 14, *) {
                self.logger?.info("Connection established")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Connection established", log: oslog, type: .info)
            }
            if betterPath || viablePath && self.canRun {
                let pathMessage = betterPath ? "We found a better path" : "We found a viable path"
                if #available(iOS 14, *) {
                    self.logger?.trace("\(pathMessage)")
                } else {
                    guard let oslog = self.oslog else { return }
                    os_log("%@", log: oslog, type: .info, pathMessage)
                }
                self.canRun = false
                let parameters: NWParameters = self.configuration.trustAll ? try TLSConfiguration.trustSelfSigned(
                    configuration.trustAll,
                    queue: configuration.queue,
                    certificates: self.configuration.certificates) : (self.configuration.url.scheme == "ws" ? .tcp : .tls)
                let newConnection = NWConnection(to: .url(self.configuration.url), using: parameters)
                newConnection.start(queue: self.configuration.queue)
                await setNewConnection(newConnection)
                //We have a new connection that we need to monitor
                await self.connect()
            }
            self.canRun = true
            try await self.receiverDelegate?.received(message: .connectionStatus(true))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.connectionStatus = true
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                try Task.checkCancellation()
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.asyncReceiverLoop(connection: self.connection)
                }
                _ = try await group.next()
                group.cancelAll()
            }
        case .failed(let error):
            if #available(iOS 14, *) {
                self.logger?.error("Connection failed with error - Error: \(error.localizedDescription)")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Connection failed with error - Error:", log: oslog, type: .info)
            }
            try await self.receiverDelegate?.received(message: .connectionStatus(false))
            try await self.handleNetworkIssue(error: error)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.connectionStatus = false
            }
        case .cancelled:
            if #available(iOS 14, *) {
                self.logger?.info("Connection cancelled")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Connection cancelled", log: oslog, type: .info)
            }
            try await self.receiverDelegate?.received(message: .connectionStatus(false))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.connectionStatus = false
            }
        default:
            if #available(iOS 14, *) {
                self.logger?.info("Connection default")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Connection default", log: oslog, type: .info)
            }
        }
    }
    
    private func setNewConnection(_ newConnection: NWConnection) async {
        self.connection = newConnection
    }
    
    //MARK: Inbound
    private func asyncReceiverLoop(connection: NWConnection) async throws {
        while self.canRun {
            try await self.receiveMessage(connection: connection)
        }
    }
    
    private func receiveMessage(connection: NWConnection) async throws {
        do {
            let message = try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<WhiteTippedMesssage, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { content, contentContext, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        let message = WhiteTippedMesssage(
                            data: content,
                            context: contentContext,
                            isComplete: isComplete
                        )
                        continuation.resume(returning: message)
                    }
                }
            })
            try await self.channelRead(message: message)
        } catch let error as NWError {
            try await self.handleNetworkIssue(error: error)
        } catch {
            //This means we did not receive a network error, but some other error was caught. Therefore we want to send the close message to the server
            try await self.handleNetworkIssue(code: .protocolCode(.goingAway))
            throw error
        }
    }
    
    
    func channelRead(message: WhiteTippedMesssage) async throws {
        guard let metadata = message.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
        switch metadata.opcode {
        case .cont:
            if #available(iOS 14, *) {
                self.logger?.trace("Received continuous WebSocketFrame")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Received continuous WebSocketFrame", log: oslog, type: .info)
            }
        case .text:
            if #available(iOS 14, *) {
                self.logger?.trace("Received text WebSocketFrame")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Received text WebSocketFrame", log: oslog, type: .info)
            }
            guard let data = message.data else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await self.receiverDelegate?.received(message: .text(text))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.textReceived = text
            }
        case .binary:
            if #available(iOS 14, *) {
                self.logger?.trace("Received binary WebSocketFrame")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Received binary WebSocketFrame", log: oslog, type: .info)
            }
            guard let data = message.data else { return }
            try await receiverDelegate?.received(message: .binary(data))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.binaryReceived = data
            }
        case .close:
            if #available(iOS 14, *) {
                self.logger?.trace("Received close WebSocketFrame")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Received close WebSocketFrame", log: oslog, type: .info)
            }
            try await handleNetworkIssue(code: metadata.closeCode)
        case .ping:
            if #available(iOS 14, *) {
                self.logger?.trace("Received ping WebSocketFrame")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Received ping WebSocketFrame", log: oslog, type: .info)
            }
            let data = Data()
            try await self.receiverDelegate?.received(message: .ping(data))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.pingReceived = data
            }
        case .pong:
            if #available(iOS 14, *) {
                self.logger?.trace("Received pong WebSocketFrame")
            } else {
                guard let oslog = self.oslog else { return }
                os_log("Received pong WebSocketFrame", log: oslog, type: .info)
            }
            let data = Data()
            try await self.receiverDelegate?.received(message: .pong(data))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.receiver.pongReceived = data
            }
            if self.configuration.wtAutoReplyPing {
                do {
                    try await self.ping(autoLoop: self.configuration.wtAutoReplyPing)
                } catch {
                    if #available(iOS 14, *) {
                        self.logger?.error("\(error.localizedDescription)")
                    } else {
                        guard let oslog = self.oslog else { return }
                        os_log("%@", log: oslog, type: .error, error.localizedDescription)
                    }
                }
            }
        @unknown default:
            fatalError("Unkown State Case")
        }
    }
    
    //MARK: Outbound
    public func sendText(_ text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await self.send(data: data, context: context)
    }
    
    public func sendBinary(_ data: Data) async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        try await self.send(data: data, context: context)
    }
    
    public func ping(autoLoop: Bool) async throws {
        if autoLoop {
            while try await suspendAndPing() {}
        } else {
            _ = try await suspendAndPing()
        }
        @Sendable func suspendAndPing() async throws -> Bool {
            try await self.sleepTask(self.configuration.pingPongInterval, performWork: {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.canRun {
                        try await self.sendPing()
                    }
                }
            })
            
            return await self.canRun
        }
    }
    
    public func pong(autoLoop: Bool) async throws {
        if autoLoop {
            while try await suspendAndPong() {}
        } else {
            _ = try await suspendAndPong()
        }
        @Sendable func suspendAndPong() async throws -> Bool {
            try await self.sleepTask(self.configuration.pingPongInterval, performWork: {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.canRun {
                        try await self.sendPong()
                    }
                }
            })
            
            return await self.canRun
        }
    }
    
    func sendPing() async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        try await self.pongHandler(metadata, queue: self.configuration.queue)
        let context = NWConnection.ContentContext(
            identifier: "ping",
            metadata: [metadata]
        )
        guard let data = "ping".data(using: .utf8) else { return }
        try await self.send(data: data, context: context)
    }
    
    func sendPong() async throws {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .pong)
        let context = NWConnection.ContentContext(
            identifier: "pong",
            metadata: [metadata]
        )
        guard let data = "pong".data(using: .utf8) else { return }
        try await self.send(data: data, context: context)
    }
    
    func pongHandler(_ metadata: NWProtocolWebSocket.Metadata, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<Void, Error>) in
            metadata.setPongHandler(queue) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        })
    }
    
    func send(data: Data, context: NWConnection.ContentContext) async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask { [weak self] in
                guard let self else { return }
                try await self.sendAsync(data: data, context: context, connection: self.connection)
            }
            _ = try await group.next()
            group.cancelAll()
        })
    }
    
    func sendAsync(
        data: Data,
        context: NWConnection.ContentContext,
        connection: NWConnection
    ) async throws -> Void {
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
    
    //MARK: Error Handling
    public func handleNetworkIssue(error: NWError? = nil, code: NWProtocolWebSocket.CloseCode? = nil) async throws {
        self.canRun = false
        
        if let code = code {
            switch code {
            case .protocolCode(let protocolCode):
                switch protocolCode {
                case .normalClosure, .protocolError:
                    //Close the connection and tell the client. A normal Closure occurs when the client expects to close the connection
                    //A protocolError indicates that some issue occured during the call andwe can no longer send events due to a non responsice socket so we will clean and close the connection.
                    try await self.notifyCloseOrError(with: error, code)
                    await self.cancelConnection()
                default:
                    let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
                    metadata.closeCode = code
                    let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
                    try await self.send(data: Data(), context: context)
                    try await self.notifyCloseOrError(with: error, code)
                    await self.cancelConnection()
                }
            default:
                try await self.notifyCloseOrError(code)
                await self.cancelConnection()
            }
        } else {
            //No WebSocket Protocol Code, meaning we received some unexpected error from the server side
            try await self.notifyCloseOrError(code)
            await self.cancelConnection()
        }
    }
    
    private func cancelConnection() async {
        self.connection.cancel()
        self.stateCancellable = nil
        self.betterPathCancellable = nil
        self.viablePathCancellable = nil
    }
    
    func notifyCloseOrError(with error: NWError? = nil, _ reason: NWProtocolWebSocket.CloseCode? = nil) async throws {
        let result = DisconnectResult(error: error, code: reason)
        try await self.receiverDelegate?.received(message: .disconnectPacket(result))
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.receiver.disconnectionPacketReceived = result
        }
    }
}
#endif


@available(iOS 14, macOS 12, *)
extension WhiteTippedConnection {
    var logger: Logger? {
        get { WTLoggerCache.readLogger(LoggerKey(self).logger) }
        set { WTLoggerCache.setLogger(newValue!, forKey: LoggerKey(self).logger) }
    }
}

@available(iOS 13, macOS 12, *)
extension WhiteTippedConnection {
    var oslog: OSLog? {
        get { return WTOSLogCache.readLogger(OSLogKey(self).logger) }
        set { WTOSLogCache.setLogger(newValue!, forKey: OSLogKey(self).logger) }
    }
}

@available(iOS 14.0, *)
final class WTLoggerCache: @unchecked Sendable {
    
    static let lock = NSLock()
    static var logger = [ObjectIdentifier: Logger]()
    
    internal class func readLogger(_ key: WhiteTippedConnection) -> LoggerKey.Value? {
        return logger[ObjectIdentifier(key)]
    }
    
    internal class func setLogger(_ value: Logger, forKey key: WhiteTippedConnection) {
        lock.lock()
        logger[ObjectIdentifier(key)] = value
        lock.unlock()
    }
}

@available(iOS 13, macOS 12, *)
final class WTOSLogCache: @unchecked Sendable {
    
    static let lock = NSLock()
    static var logger = [ObjectIdentifier: OSLog]()
    
    internal class func readLogger(_ key: WhiteTippedConnection) -> OSLogKey.Value? {
        return logger[ObjectIdentifier(key)]
    }
    
    internal class func setLogger(_ value: OSLog, forKey key: WhiteTippedConnection) {
        lock.lock()
        logger[ObjectIdentifier(key)] = value
        lock.unlock()
    }
}

internal protocol CacheKey {
    associatedtype Value
}

@available(iOS 14.0, *)
internal final class LoggerKey: CacheKey {
    typealias Value = Logger
    
    var logger: WhiteTippedConnection
    init(_ logger: WhiteTippedConnection) {
        self.logger = logger
    }
}

@available(iOS 13, macOS 12, *)
internal final class OSLogKey: CacheKey {
    typealias Value = OSLog
    
    var logger: WhiteTippedConnection
    init(_ logger: WhiteTippedConnection) {
        self.logger = logger
    }
}
