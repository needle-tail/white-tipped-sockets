//
//  ListenerSequence.swift
//  
//
//  Created by Cole M on 4/16/22.
//

import Foundation
import DequeModule
import Atomics


public struct WhiteTippedAsyncSequence<T>: AsyncSequence {

    public typealias Element = WTASequenceStateMachine.WTASequenceResult<T>
    
    public let consumer: WhiteTippedAsyncConsumer<T>
    
    public init(consumer: WhiteTippedAsyncConsumer<T>) {
        self.consumer = consumer
    }
    
    public func makeAsyncIterator() -> Iterator<T> {
        return WhiteTippedAsyncSequence.Iterator(consumer: consumer)
    }
    
    
}

extension WhiteTippedAsyncSequence {
    public struct Iterator<T>: AsyncIteratorProtocol {
        
        public typealias Element = WTASequenceStateMachine.WTASequenceResult<T>
        
        public let consumer: WhiteTippedAsyncConsumer<T>
        
        public init(consumer: WhiteTippedAsyncConsumer<T>) {
            self.consumer = consumer
        }
        
        public func next() async throws -> WTASequenceStateMachine.WTASequenceResult<T>? {
            let stateMachine = await consumer.stateMachine
            return await withTaskCancellationHandler {
                let result = await consumer.next()
                switch result {
                case .ready(let sequence):
                   return .success(sequence)
                case .finished:
                   return .finished
                }
            } onCancel: {
                stateMachine.cancel()
            }
        }
    }
}
   
public actor WhiteTippedAsyncConsumer<T> {
    
    public var deque = Deque<T>()
    public var stateMachine = WTASequenceStateMachine()
    
    public init(deque: Deque<T> = Deque<T>()) {
        self.deque = deque
    }
    
    public func feedConsumer(_ items: [T]) async {
        deque.append(contentsOf: items)
    }
    
    public func next() async -> WTASequenceStateMachine.NextWTAResult<T> {
        switch stateMachine.state {
        case 0:
            guard let item = deque.popFirst() else { return .finished }
            return .ready(item)
        case 1:
            return .finished
        default:
            return .finished
        }
    }
}

public final class WTASequenceStateMachine: Sendable {
    
    public init() {}
    
    public enum WTAConsumedState: Int, Sendable, CustomStringConvertible {
        case consumed, waiting
        
        public var description: String {
                switch self.rawValue {
                case 0:
                    return "consumed"
                case 1:
                    return "waiting"
                default:
                    return ""
                }
            }
        }
    
    public enum WTASequenceResult<T: Sendable>: Sendable {
        case success(T), finished
    }

    public enum NextWTAResult<T: Sendable>: Sendable {
        case ready(T), finished
    }
    
    private let protectedState = ManagedAtomic<Int>(WTAConsumedState.consumed.rawValue)
     
    public var state: WTAConsumedState.RawValue {
        get { protectedState.load(ordering: .acquiring) }
        set { protectedState.store(newValue, ordering: .relaxed) }
    }

    func cancel() {
        state = 0
    }
}

