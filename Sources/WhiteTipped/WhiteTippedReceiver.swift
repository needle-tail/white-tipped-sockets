//
//  WhiteTippedReciever.swift
//  
//
//  Created by Cole M on 6/16/22.
//
#if canImport(Network) && canImport(Combine) && canImport(SwiftUI)
import Foundation
@preconcurrency import Network

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct DisconnectResult: Sendable {
    public var error: NWError?
    public var code: NWProtocolWebSocket.CloseCode?
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class WhiteTippedReciever: NSObject, ObservableObject, @unchecked Sendable {
    @Published @objc dynamic public var textReceived = ""
    @Published @objc dynamic public var binaryReceived = Data()
    @Published @objc dynamic public var pongReceived = Data()
    @Published @objc dynamic public var pingReceived = Data()
    @Published @objc dynamic public var betterPathReceived = false
    @Published @objc dynamic public var viablePathReceived = false
    @Published @objc dynamic public var connectionStatus = false
    @Published public var disconnectionPacketReceived: DisconnectResult?
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public enum MessagePacket {
    case text(String)
    case binary(Data)
    case ping(Data)
    case pong(Data)
    case betterPath(Bool)
    case viablePath(Bool)
    case connectionStatus(Bool)
    case disconnectPacket(DisconnectResult)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol WhiteTippedRecieverDelegate: AnyObject, Sendable {
    func received(message packet: MessagePacket) async throws
    func received(_ packet: MessagePacket)
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public extension WhiteTippedRecieverDelegate {
    func received(message packet: MessagePacket) async throws {}
    func received(_ packet: MessagePacket) {}
}
#endif
