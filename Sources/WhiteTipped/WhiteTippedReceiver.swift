//
//  WhiteTippedReciever.swift
//  
//
//  Created by Cole M on 6/16/22.
//
#if canImport(Network) && canImport(Combine) && canImport(SwiftUI)
import Foundation
import Network

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct DisconnectResult {
    public var error: NWError?
    public var code: NWProtocolWebSocket.CloseCode
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
open class WhiteTippedReciever: NSObject, ObservableObject, @unchecked Sendable {
    @Published @objc dynamic open var textReceived = ""
    @Published @objc dynamic open var binaryReceived = Data()
    @Published @objc dynamic open var pongReceived = Data()
    @Published @objc dynamic open var betterPathReceived = false
    @Published @objc dynamic open var viablePathReceived = false
    @Published @objc dynamic open var connectionStatus = false
    @Published open var disconnectionPacketReceived: DisconnectResult?
}

public enum MessageType {
    case text, binary, ping, pong, betterPath, viablePath, connectionStatus, disconnectPacket
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct MessagePacket {
    public var text: String?
    public var binary: Data?
    public var ping: Data?
    public var pong: Data?
    public var betterPath: Bool?
    public var viablePath: Bool?
    public var connectionStatus: Bool?
    public var disconnectPacket: DisconnectResult?
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol WhiteTippedRecieverProtocol: AnyObject {
    
    func received(_ type: MessageType, packet: MessagePacket)
}
#endif
