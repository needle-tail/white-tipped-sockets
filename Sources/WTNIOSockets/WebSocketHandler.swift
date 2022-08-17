//
//  File.swift
//  
//
//  Created by Cole M on 6/22/22.
//

import Foundation
import NIOCore
import NIOWebSocket
import WTHelpers


public class WebSocketHandler: ChannelInboundHandler {
    
    public typealias InboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame
    
    let websocket: WebSocket
    
    init(websocket: WebSocket) {
        self.websocket = websocket
    }

    public func channelActive(context: ChannelHandlerContext) {
        print("Channel Active")
    }
    
    public func channelInactive(context: ChannelHandlerContext) {
        print("Channel InActive")
    }
    
    public func channelRegistered(context: ChannelHandlerContext) {
        print("Channel Registered")
    }
    
    public func channelUnregistered(context: ChannelHandlerContext) {
        print("Channel Unregistered")
    }
    
    public func channelReadComplete(context: ChannelHandlerContext) {
        print("Channel Read Complete")
        context.flush()
    }
    
    let consumer = FrameConsumer()
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        print("Channel Read")
        let frame = self.unwrapInboundIn(data)
      
        consumer.feedConsumer(FrameStruct(frame: frame, context: context))
        
        let task = Task {
            do {
                for try await frameStruct in FrameSequence(consumer: consumer) {
                    switch frameStruct {
                    case .success(let result):
                        guard let frame = result.frame else { return }
                        guard let context = result.context else { return }
                        try await websocket.handleRead(frame, context: context)
                    case .retry:
                        break
                    case .finished:
                    break
                    }
                }
            } catch {
                print(error)
            }
        }
        task.cancel()
    }
    
    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        print("Channel Written")
    }
}


public struct FrameSequence: AsyncSequence {
    public typealias Element = FrameSequenceResult
    
    
    let consumer: FrameConsumer
    
    public init(consumer: FrameConsumer) {
        self.consumer = consumer
    }
    
    public func makeAsyncIterator() -> Iterator {
        return FrameSequence.Iterator(consumer: consumer)
    }
    
    
}

extension FrameSequence {
    public struct Iterator: AsyncIteratorProtocol {
        
        public typealias Element = FrameSequenceResult
        
        let consumer: FrameConsumer
        
       public init(consumer: FrameConsumer) {
            self.consumer = consumer
        }
        
        public mutating func next() async throws -> FrameSequenceResult? {
            let result = consumer.next()
            var res: FrameSequenceResult?
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


public enum FrameSequenceResult {
    case success(FrameStruct), retry, finished
}

public enum NextFrameResult {
    case ready(FrameStruct) , preparing, finished
}

public struct FrameStruct {
    public var frame: WebSocketFrame?
    public var context: ChannelHandlerContext?
    
    public init(
        frame: WebSocketFrame?,
        context: ChannelHandlerContext
    ) {
        self.frame = frame
        self.context = context
    }
}

public var consumedState = ConsumedState.consumed
public var dequeuedConsumedState = ConsumedState.consumed
var nextResult = NextFrameResult.preparing

public final class FrameConsumer {
    
    public var queue = FrameArray<FrameStruct>()
    
    public init() {}
    
    
    public func feedConsumer(_ conversation: FrameStruct) {
        queue.enqueue(conversation)
    }
    
    func next() -> NextFrameResult {
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


public struct FrameArray<T>: ListenerQueue {
    
    
    private var enqueueArray: [T] = []
    public var isEmpty: Bool {
        return enqueueArray.isEmpty
    }
    
    public init() {}
    
    public var peek: T? {
        return enqueueArray.first
    }
    
    
    mutating public func enqueue(_ element: T) {
    
        //Then we append the element
        enqueueArray.append(element)
    }
    
    
    @discardableResult
    mutating public func dequeue() -> T? {
        return isEmpty ? nil : enqueueArray.removeFirst()
    }
}
