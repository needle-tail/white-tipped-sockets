//
//  NWConnectionState.swift
//  
//
//  Created by Cole M on 6/16/22.
//

#if canImport(Network) && canImport(Combine) && canImport(SwiftUI)
import Foundation
import Network

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public class ObservableNWConnectionState: NSObject, ObservableObject {
    @Published public var currentState: NWConnection.State = .setup
    @Published public var listenerState: NWListener.State = .setup
    @Published public var connection: NWConnection?
    @Published public var betterPath: Bool = false
    @Published public var viablePath: Bool = false
}

@available(macOS 10.15, iOS 12, tvOS 13, watchOS 6, *)
public class NWConnectionState: NSObject {
    
    public override init() {
        self.currentState = { _ in }
        self.listenerState = { _ in }
        self.connection = { _ in }
        self.betterPath = { _ in }
        self.viablePath = { _ in }
    }
    
    public var currentState: (NWConnection.State) -> ()
    public var listenerState: (NWListener.State) -> ()
    public var connection: (NWConnection) -> ()
    public var betterPath: (Bool) -> ()
    public var viablePath: (Bool) -> ()
}
#endif
