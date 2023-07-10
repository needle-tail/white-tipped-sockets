//
//  ListenerStruct.swift
//  
//
//  Created by Cole M on 7/4/23.
//

import Foundation

#if canImport(Network)
@preconcurrency import Network

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public struct WhiteTippedMesssage: Sendable {
    public var data: Data?
    public var context: NWConnection.ContentContext?
    public var isComplete: Bool
    public var session: NWConnection?
    
    public init(
        data: Data?,
        context: NWConnection.ContentContext?,
        isComplete: Bool,
        session: NWConnection? = nil
    ) {
        self.data = data
        self.context = context
        self.isComplete = isComplete
        self.session = session
    }
}
#endif
