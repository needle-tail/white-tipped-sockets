//
//  File.swift
//  
//
//  Created by Cole M on 4/23/22.
//

import Foundation
import Network

public enum StateResult {
    case succes(NWConnection.State), fail
}

public struct StateSequence: AsyncSequence {
    public typealias Element = StateResult
    
    
    let consumer: StateConsumer
    public init(consumer: StateConsumer) {
        self.consumer = consumer
    }
    
    public func makeAsyncIterator() -> Iterator {
        return StateSequence.Iterator(consumer: consumer)
    }
    
    
}

extension StateSequence {
    public struct Iterator: AsyncIteratorProtocol {
        
        public typealias Element = StateResult
        
        let consumer: StateConsumer
        public init(consumer: StateConsumer) {
            self.consumer = consumer
        }
        
        mutating public func next() async throws -> StateResult? {
            let result = consumer.next()
            var res: StateResult?
            switch result {
            case .ready(let state):
                res = .succes(state)
            case .finished:
                res = .fail
            }
            
            return res
        }
    }
}

public enum ConsumedNWState {
    case consumed, waiting
}

enum NextState {
    case ready(NWConnection.State), finished
}

public var consumedNWState = ConsumedNWState.consumed
public var dequeuedConnectionState = ConsumedNWState.consumed
var nextState = NextState.finished

public final class StateConsumer {
    
    internal var queue = ListenerStack<NWConnection.State>()
    
    public init() {}
    
    
    public func feedConsumer(_ conversation: NWConnection.State) async {
        queue.enqueue(conversation)
    }
    
    func next() -> NextState {
        switch dequeuedConsumedState {
        case .consumed:
            consumedState = .waiting
            guard let state = queue.dequeue() else { return .finished }
            return .ready(state)
        case .waiting:
            return .finished
        }
    }
}
