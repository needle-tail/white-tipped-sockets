//
//  WhiteTippedReciever.swift
//  
//
//  Created by Cole M on 6/16/22.
//
#if canImport(Network) && canImport(Combine) && canImport(SwiftUI)
import Combine
import Foundation
import Network

public struct DisconnectResult {
    public var error: NWError?
    public var code: NWProtocolWebSocket.CloseCode
}

public class WhiteTippedReciever {
    public let textReceived = PassthroughSubject<String, Never>()
    public let binaryReceived = PassthroughSubject<Data, Never>()
    public let pongReceived = PassthroughSubject<Data, Never>()
    public let disconnectionPacketReceived = PassthroughSubject<DisconnectResult, Never>()
    public let betterPathReceived = PassthroughSubject<Bool, Never>()
    public let viablePathReceived = PassthroughSubject<Bool, Never>()
    public let connectionStatus = PassthroughSubject<Bool, Never>()
}
#endif
