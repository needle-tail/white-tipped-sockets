//
//  ListenerSequence.swift
//  
//
//  Created by Cole M on 4/16/22.
//

#if canImport(Network)
import Foundation
import Network

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
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

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
extension ListenerSequence {
    public struct Iterator: AsyncIteratorProtocol {
        
        public typealias Element = SequenceResult
        
        let consumer: ListenerConsumer
        
       public init(consumer: ListenerConsumer) {
            self.consumer = consumer
        }
        
        mutating public func next() async throws -> SequenceResult? {
            let result = await consumer.next()
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

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public enum SequenceResult {
    case success(ListenerStruct), retry, finished
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public enum NextResult {
    case ready(ListenerStruct) , preparing, finished
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
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
@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
var nextResult = NextResult.preparing

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public final class ListenerConsumer {
    
    public var queue = ListenerStack<ListenerStruct>()
    
    public init() {}
    
    
    public func feedConsumer(_ conversation: ListenerStruct) async {
        await queue.enqueue(conversation)
    }
    
    func next() async -> NextResult {
        switch dequeuedConsumedState {
        case .consumed:
            consumedState = .waiting
            guard let listener = await queue.dequeue() else { return .finished }
            return .ready(listener)
        case .waiting:
            return .preparing
        }
    }
}


@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public protocol ListenerQueue {
    associatedtype Element
    func enqueue(_ element: Element) async
    func dequeue() async -> Element?
//    var isEmpty: Bool { get }
//    var peek: Element? { get }
}

@available(macOS 10.15, iOS 13, tvOS 13, watchOS 6, *)
public actor ListenerStack<T>: ListenerQueue {
    
    
    private var enqueueStack: [T] = []
    private var dequeueStack: [T] = []
//    public var isEmpty: Bool {
//        return dequeueStack.isEmpty && enqueueStack.isEmpty
//    }
    
    public init() {}
    
//    public var peek: T? {
//        return !dequeueStack.isEmpty ? dequeueStack.last : enqueueStack.first
//    }
    
    
    public func enqueue(_ element: T) async {
        //If stack is empty we want to set the array to the enqueue stack
        if enqueueStack.isEmpty {
            dequeueStack = enqueueStack
        }
        //Then we append the element
        enqueueStack.append(element)
    }
    
    
    @discardableResult
    public func dequeue() async -> T? {
        if dequeueStack.isEmpty {
            dequeueStack = enqueueStack.reversed()
            enqueueStack.removeAll()
        }
        return dequeueStack.popLast()
    }
}
#endif
