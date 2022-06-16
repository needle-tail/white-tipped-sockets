//
//  NWConnectionState.swift
//  
//
//  Created by Cole M on 6/16/22.
//

import Foundation
import Network

class NWConnectionState: NSObject, ObservableObject {
    @Published var currentState: NWConnection.State = .preparing
    @Published var betterPath: Bool = false
    @Published var viablePath: Bool = false
}
