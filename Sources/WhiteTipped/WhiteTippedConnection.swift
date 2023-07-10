
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
        let lock = NSLock()
        
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
            wtAutoReplyPing: Bool = false
        ) {
            lock.lock()
            self.queue = DispatchQueue(label: queue, attributes: .concurrent)
            lock.unlock()
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
            configuration.queue,
            certificates: configuration.certificates) : (configuration.url.scheme == "ws" ? .tcp : .tls)
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        connection = NWConnection(to: .url(configuration.url), using: parameters)
    }
    
    func createLogger() async {
        if #available(iOS 14, *) {
            logger = Logger(subsystem: "WhiteTipped", category: "WhiteTippedConnection")
        } else {
            oslog = OSLog(subsystem: "WhiteTipped", category: "WhiteTippedConnection")
        }
    }
    
    deinit {
        //        print("RECLAIMING MEMORY IN WTS")
    }
    
    public func connect() async {
        await createLogger()
        connection.start(queue: configuration.queue)
        pathHandlers()
        do {
            
            try await withThrowingTaskGroup(of: Void.self, body: { group in
                try Task.checkCancellation()
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.betterPath()
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.viablePath()
                }
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await self.monitorConnection()
                }
                _ = try await group.next()
                group.cancelAll()
            })
        } catch {
            if #available(iOS 14, *) {
                logger?.error("\(error)")
            } else {
                guard let oslog = oslog else { return }
                os_log("@%", log: oslog, type: .error, error.localizedDescription)
            }
        }
    }
    
    private func pathHandlers() {
        if #available(iOS 15.0, *) {
            stateCancellable = connectionState.publisher(for: \.currentState) as? Cancellable
            betterPathCancellable = connectionState.publisher(for: \.betterPath) as? Cancellable
            viablePathCancellable = connectionState.publisher(for: \.viablePath) as? Cancellable
        }
        
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {return}
            self.connectionState.currentState = state
        }
        
        connection.betterPathUpdateHandler = { [weak self] value in
            guard let self else {return}
            self.connectionState.betterPath = value
        }
        
        connection.viabilityUpdateHandler = { [weak self] value in
            guard let self else {return}
            self.connectionState.viablePath = value
        }
    }
    
    private func betterPath() async throws {
        if #available(iOS 15.0, *) {
            for await result in connectionState.$betterPath.values {
                try await self.receiverDelegate?.received(message: .betterPath(result))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.receiver.betterPathReceived = result
                }
                if result {
                    try await withThrowingTaskGroup(of: Void.self, body: { group in
                        try Task.checkCancellation()
                        group.addTask { [weak self] in
                            guard let self else { return }
                            try await self.monitorConnection()
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    })
                }
            }
        } else {
            betterPathCancellable = connectionState.$betterPath.sink { [weak self] result in
                guard let self else { return }
                self.asyncClosureBridge { [weak self] in
                    guard let self else { return }
                    try await self.receiverDelegate?.received(message: .betterPath(result))
                }
                self.asyncClosureBridge { @MainActor [weak self] in
                    guard let self else { return }
                    self.receiver.betterPathReceived = result
                }
                
                if result {
                    self.asyncClosureBridge { [weak self] in
                        guard let self else { return }
                        try await self.monitorConnection()
                    }
                }
            }
        }
    }
    
    private func viablePath() async throws {
        if #available(iOS 15.0, *) {
            for await result in connectionState.$viablePath.values {
                try await self.receiverDelegate?.received(message: .viablePath(result))
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.receiver.viablePathReceived = result
                }
                
                if result && connectionState.currentState != .ready {
                    try await withThrowingTaskGroup(of: Void.self, body: { group in
                        try Task.checkCancellation()
                        group.addTask { [weak self] in
                            guard let self else { return }
                            try await self.monitorConnection()
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    })
                }
            }
        } else {
            viablePathCancellable = connectionState.$viablePath.sink { [weak self] result in
                guard let self else { return }
                self.asyncClosureBridge { [weak self] in
                    guard let self else { return }
                    try await self.receiverDelegate?.received(message: .viablePath(result))
                }
                self.asyncClosureBridge { @MainActor [weak self] in
                    guard let self else { return }
                    self.receiver.viablePathReceived = result
                }
                
                if result {
                    self.asyncClosureBridge { [weak self] in
                        guard let self else { return }
                        try await self.monitorConnection()
                    }
                }
            }
        }
    }
    
    nonisolated private func asyncClosureBridge(completion: @escaping () async throws  -> Void) {
        Task {
            try Task.checkCancellation()
            try await completion()
        }
    }
    
    private func monitorConnection() async throws {
        if #available(iOS 15.0, *) {
            for await state in self.connectionState.$currentState.values {
                try await monitorConnectionLogic(
                    state,
                    betterPath: receiver.betterPathReceived,
                    viablePath: receiver.viablePathReceived
                )
            }
        } else {
            currentStateCancellable = connectionState.$currentState.sink { [weak self] state in
                guard let self else { return }
                self.asyncClosureBridge { [weak self] in
                    guard let self else { return }
                    try await self.monitorConnectionLogic(
                        state,
                        betterPath: receiver.betterPathReceived,
                        viablePath: receiver.viablePathReceived
                    )
                }
            }
        }
    }
    
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
                guard let oslog = oslog else { return }
                os_log("Connection setup", log: oslog, type: .info)
            }
        case .waiting(let status):
            if #available(iOS 14, *) {
                self.logger?.info("Connection waiting with status - Status: \(status.localizedDescription)")
            } else {
                guard let oslog = oslog else { return }
                os_log("Connection waiting with status - Status:", log: oslog, type: .info)
            }
        case .preparing:
            if #available(iOS 14, *) {
                self.logger?.info("Connection preparing")
            } else {
                guard let oslog = oslog else { return }
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
                DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(self.configuration.connectionTimeout)) { [weak self] in
                    guard let self else { return }
                    self.asyncClosureBridge { [weak self] in
                        guard let self else { return }
                        if await self.connection.state != .ready {
                            await self.connection.stateUpdateHandler?(.failed(.posix(.ETIMEDOUT)))
                        }
                    }
                }
            }
        case .ready:
            if #available(iOS 14, *) {
                self.logger?.info("Connection established")
            } else {
                guard let oslog = oslog else { return }
                os_log("Connection established", log: oslog, type: .info)
            }
            if betterPath || viablePath && canRun {
                let pathMessage = betterPath ? "We found a better path" : "We found a viable path"
                if #available(iOS 14, *) {
                    self.logger?.trace("\(pathMessage)")
                } else {
                    guard let oslog = oslog else { return }
                    os_log("%@", log: oslog, type: .info, pathMessage)
                }
                canRun = false
                let parameters: NWParameters = self.configuration.trustAll ? try TLSConfiguration.trustSelfSigned(
                    configuration.queue,
                    certificates: self.configuration.certificates) : (self.configuration.url.scheme == "ws" ? .tcp : .tls)
                let newConnection = NWConnection(to: .url(self.configuration.url), using: parameters)
                newConnection.start(queue: configuration.queue)
                await setNewConnection(newConnection)
                self.pathHandlers()
            }
            canRun = true
            try await self.receiverDelegate?.received(message: .connectionStatus(true))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.connectionStatus = true
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                try Task.checkCancellation()
                group.addTask { [weak self] in
                    guard let self else { return }
                    try await asyncReceiverLoop(connection: connection)
                }
                _ = try await group.next()
                group.cancelAll()
            }
        case .failed(let error):
            if #available(iOS 14, *) {
                self.logger?.info("Connection failed with error - Error: \(error)")
            } else {
                guard let oslog = oslog else { return }
                os_log("Connection failed with error - Error:", log: oslog, type: .info)
            }
            try await self.receiverDelegate?.received(message: .connectionStatus(false))
            try await handleNetworkIssue(error: error, code: .protocolCode(.abnormalClosure))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.connectionStatus = false
            }
        case .cancelled:
            if #available(iOS 14, *) {
                self.logger?.info("Connection cancelled")
            } else {
                guard let oslog = oslog else { return }
                os_log("Connection cancelled", log: oslog, type: .info)
            }
            try await self.receiverDelegate?.received(message: .connectionStatus(false))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.connectionStatus = false
            }
        default:
            if #available(iOS 14, *) {
                self.logger?.info("Connection default")
            } else {
                guard let oslog = oslog else { return }
                os_log("Connection default", log: oslog, type: .info)
            }
        }
    }
    
    private func setNewConnection(_ newConnection: NWConnection) async {
        self.connection = newConnection
    }
    
    private func asyncReceiverLoop(connection: NWConnection) async throws {
        while canRun {
            try await self.receiveMessage(connection: connection)
        }
    }
    
    private func receiveMessage(connection: NWConnection) async throws {
        do {
            let message = try await withCheckedThrowingContinuation({ (continuation: CheckedContinuation<WhiteTippedMesssage, Error>) in
                connection.receiveMessage(completion: { completeContent, contentContext, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        let message = WhiteTippedMesssage(
                            data: completeContent,
                            context: contentContext,
                            isComplete: isComplete
                        )
                        continuation.resume(returning: message)
                    }
                })
            })
            try await channelRead(message: message)
        } catch let error as NWError {
            try await reportErrorOrDisconnection(error)
        } catch {
            await cancelConnection()
            throw error
        }
    }
    
    private func reportErrorOrDisconnection(_ error: NWError) async throws {
        if shouldReportNWError(error) {
            try await handleNetworkIssue(error: error)
        }
        if isDisconnectionNWError(error) {
            try await handleNetworkIssue(error: error, code: .protocolCode(.goingAway))
        }
    }

    
    /// Determine if a Network error should be reported.
    ///
    /// POSIX errors of either `ENOTCONN` ("Socket is not connected") or
    /// `ECANCELED` ("Operation canceled") should not be reported if the disconnection was intentional.
    /// All other errors should be reported.
    /// - Parameter error: The `NWError` to inspect.
    /// - Returns: `true` if the error should be reported.
    private func shouldReportNWError(_ error: NWError) -> Bool {
        if case let .posix(code) = error,
           code == .ENOTCONN || code == .ECANCELED {
            return false
        }
    return true
}

    /// Determine if a Network error represents an unexpected disconnection event.
    /// - Parameter error: The `NWError` to inspect.
    /// - Returns: `true` if the error represents an unexpected disconnection event.
    private func isDisconnectionNWError(_ error: NWError) -> Bool {
        if case let .posix(code) = error,
           code == .ETIMEDOUT
            || code == .ENOTCONN
            || code == .ECANCELED
            || code == .ENETDOWN
            || code == .ECONNABORTED {
            return true
        } else {
            return false
        }
    }
        
    func channelRead(message: WhiteTippedMesssage) async throws {
        guard let metadata = message.context?.protocolMetadata.first as? NWProtocolWebSocket.Metadata else { return }
        switch metadata.opcode {
        case .cont:
            if #available(iOS 14, *) {
                logger?.trace("Received continuous WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received continuous WebSocketFrame", log: oslog, type: .info)
            }
        case .text:
            if #available(iOS 14, *) {
                logger?.trace("Received text WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received text WebSocketFrame", log: oslog, type: .info)
            }
            guard let data = message.data else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            try await receiverDelegate?.received(message: .text(text))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.textReceived = text
            }
        case .binary:
            if #available(iOS 14, *) {
                logger?.trace("Received binary WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received binary WebSocketFrame", log: oslog, type: .info)
            }
            guard let data = message.data else { return }
            try await receiverDelegate?.received(message: .binary(data))
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiver.binaryReceived = data
            }
        case .close:
            if #available(iOS 14, *) {
                logger?.trace("Received close WebSocketFrame")
            } else {
                guard let oslog = oslog else { return }
                os_log("Received close WebSocketFrame", log: oslog, type: .info)
            }
            try await handleNetworkIssue(code: .protocolCode(.goingAway))
        case .ping:
            if #available(iOS 14, *) {
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
            if #available(iOS 14, *) {
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
            if self.configuration.wtAutoReplyPing {
                do {
                    try await ping(autoLoop: self.configuration.wtAutoReplyPing)
                } catch {
                    if #available(iOS 14, *) {
                        logger?.error("\(error)")
                    } else {
                        guard let oslog = oslog else { return }
                        os_log("%@", log: oslog, type: .error, error.localizedDescription)
                    }
                }
            }
        @unknown default:
            fatalError("Unkown State Case")
        }
    }
    
    public func handleNetworkIssue(error: NWError? = nil, code: NWProtocolWebSocket.CloseCode? = nil) async throws {
        canRun = false
            //NORMAL
        if code == .protocolCode(.normalClosure) {
            try await notifyCloseOrError(code)
            await cancelConnection()
            //ONLY ERROR, DON'T CLOSE
        } else if let error = error, code == nil {
            try await notifyCloseOrError(with: error)
        } else {
            //CLOSE
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            guard let code = code else { return }
            metadata.closeCode = code
            try await notifyCloseOrError(with: error, code)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            try await send(data: Data(), context: context)
            await cancelConnection()
        }
    }
    
    private func cancelConnection() async {
        connection.cancel()
        stateCancellable = nil
        betterPathCancellable = nil
        viablePathCancellable = nil
    }
    
    func notifyCloseOrError(with error: NWError? = nil, _ reason: NWProtocolWebSocket.CloseCode? = nil) async throws {
        let result = DisconnectResult(error: error, code: reason)
        try await receiverDelegate?.received(message: .disconnectPacket(result))
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.receiver.disconnectionPacketReceived = result
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
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        try await send(data: data, context: context)
    }
    
    public func ping(autoLoop: Bool) async throws {
        if autoLoop {
            while try await suspendAndPing() {}
        } else {
            _ = try await suspendAndPing()
        }
        @Sendable func suspendAndPing() async throws -> Bool {
            try await sleepTask(configuration.pingPongInterval, performWork: {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.canRun {
                        try await self.sendPing()
                    }
                }
            })
            
            return await canRun
        }
    }
    
    public func pong(autoLoop: Bool) async throws {
        if autoLoop {
            while try await suspendAndPong() {}
        } else {
            _ = try await suspendAndPong()
        }
        @Sendable func suspendAndPong() async throws -> Bool {
            try await sleepTask(configuration.pingPongInterval, performWork: {
                Task { [weak self] in
                    guard let self else { return }
                    if await self.canRun {
                        try await self.sendPong()
                    }
                }
            })
            
            return await canRun
        }
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
        guard let data = "pong".data(using: .utf8) else { return }
        try await send(data: data, context: context)
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
    
    func send(data: Data, context: NWConnection.ContentContext) async throws {
        try await withThrowingTaskGroup(of: Void.self, body: { group in
            try Task.checkCancellation()
            group.addTask {
                try await self.sendAsync(data: data, context: context)
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
