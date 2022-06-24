//
//  File.swift
//  
//
//  Created by Cole M on 6/22/22.
//

import Foundation
import NIOCore
import NIOWebSocket



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
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        print("Channel Read")
        let frame = self.unwrapInboundIn(data)
      
        let task = Task {
            try await websocket.handleRead(frame, context: context)
        }
        task.cancel()
    }
    
    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        print("Channel Written")
    }
}
