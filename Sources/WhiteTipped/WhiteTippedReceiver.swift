//
//  WhiteTippedReciever.swift
//  
//
//  Created by Cole M on 6/16/22.
//
#if canImport(Network) && canImport(Combine) && canImport(SwiftUI)
import Foundation
import Network

public struct DisconnectResult {
    public var error: NWError?
    public var code: NWProtocolWebSocket.CloseCode
}

open class WhiteTippedReciever: NSObject, ObservableObject, @unchecked Sendable {
    @Published @objc dynamic open var textReceived = ""
    @Published @objc dynamic open var binaryReceived = Data()
    @Published @objc dynamic open var pongReceived = Data()
    @Published @objc dynamic open var betterPathReceived = false
    @Published @objc dynamic open var viablePathReceived = false
    @Published @objc dynamic open var connectionStatus = false
    @Published open var disconnectionPacketReceived: DisconnectResult?
    
//    public init() {}
}
#endif
