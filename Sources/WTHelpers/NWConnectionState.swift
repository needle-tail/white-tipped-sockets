//
//  NWConnectionState.swift
//  
//
//  Created by Cole M on 6/16/22.
//

#if canImport(Network) && canImport(Combine) && canImport(SwiftUI)
import Foundation
import Network

public class NWConnectionState: NSObject, ObservableObject {
    @Published public var currentState: NWConnection.State = .preparing
    @Published public var listenerState: NWListener.State = .setup
    @Published public var connection: NWConnection?
    @Published public var betterPath: Bool = false
    @Published public var viablePath: Bool = false
}
#endif
