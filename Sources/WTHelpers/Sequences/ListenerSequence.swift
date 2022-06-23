//
//  ListenerSequence.swift
//  
//
//  Created by Cole M on 4/16/22.
//

import Foundation

public struct ListenerSequence: AsyncSequence {
    public typealias Element = SequenceResult
    
    
    let consumer: ListenerConsumer
    
    public init(consumer: ListenerConsumer) {
        self.consumer = consumer
    }
    
    public func makeAsyncIterator() -> Iterator {
        return ListenerSequence.Iterator(consumer: consumer)
    }
    
    
}

extension ListenerSequence {
    public struct Iterator: AsyncIteratorProtocol {
        
        public typealias Element = SequenceResult
        
        let consumer: ListenerConsumer
        
       public init(consumer: ListenerConsumer) {
            self.consumer = consumer
        }
        
        mutating public func next() async throws -> SequenceResult? {
            let result = consumer.next()
            var res: SequenceResult?
            switch result {
            case .ready(let sequence):
                res = .success(sequence)
            case .preparing:
                res = .retry
            case .finished:
                res = .finished
            }
            
            return res
        }
    }
}

public enum ConsumedState {
    case consumed, waiting
}

public enum SequenceResult {
    case success(ListenerStruct), retry, finished
}

public enum NextResult {
    case ready(ListenerStruct) , preparing, finished
}

public struct ListenerStruct {
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

public var consumedState = ConsumedState.consumed
public var dequeuedConsumedState = ConsumedState.consumed
var nextResult = NextResult.preparing

public final class ListenerConsumer {
    
    public var queue = ListenerStack<ListenerStruct>()
    
    public init() {}
    
    
    public func feedConsumer(_ conversation: ListenerStruct) {
        queue.enqueue(conversation)
    }
    
    func next() -> NextResult {
        switch dequeuedConsumedState {
        case .consumed:
            consumedState = .waiting
            guard let listener = queue.dequeue() else { return .finished }
            return .ready(listener)
        case .waiting:
            return .preparing
        }
    }
}



public protocol ListenerQueue {
    associatedtype Element
    mutating func enqueue(_ element: Element)
    mutating func dequeue() -> Element?
    var isEmpty: Bool { get }
    var peek: Element? { get }
}

public struct ListenerStack<T>: ListenerQueue {
    
    
    private var enqueueStack: [T] = []
    private var dequeueStack: [T] = []
    public var isEmpty: Bool {
        return dequeueStack.isEmpty && enqueueStack.isEmpty
    }
    
    
    public var peek: T? {
        return !dequeueStack.isEmpty ? dequeueStack.last : enqueueStack.first
    }
    
    
    mutating public func enqueue(_ element: T) {
        //If stack is empty we want to set the array to the enqueue stack
        if enqueueStack.isEmpty {
            dequeueStack = enqueueStack
        }
        //Then we append the element
        enqueueStack.append(element)
    }
    
    
//    @discardableResult
    mutating public func dequeue() -> T? {
        
        if dequeueStack.isEmpty {
            dequeueStack = enqueueStack.reversed()
            enqueueStack.removeAll()
        }
        return dequeueStack.popLast()
    }
}
