//
//  File.swift
//  
//
//  Created by Cole M on 6/24/22.
//

import Foundation
import NIOCore
import NIOWebSocket

@available(iOS 13, macOS 12, *)
public class WebSocket {
    
    var channel: Channel
    private var awaitingClose: Bool = false
    
    init(channel: Channel) {
        self.channel = channel
    }
    
    
    public func handleRead(_ frame: WebSocketFrame, context: ChannelHandlerContext) async throws {
        switch frame.opcode {
        case .connectionClose:
            try await self.receivedClose(context: context, frame: frame)
        case .ping:
            print("ping")
//           try await self.pong(context: context, frame: frame)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
//            print(text)
        case .binary, .continuation, .pong:
            // We ignore these frames.
            break
        default:
            // Unknown frames are errors.
           try await self.closeOnError(context: context)
        }
        
    }
    
    
    private func sendTime(context: ChannelHandlerContext) async throws {
        guard context.channel.isActive else { return }

        // We can't send if we sent a close message.
        guard !self.awaitingClose else { return }

        // We can't really check for error here, but it's also not the purpose of the
        // example so let's not worry about it.
        let theTime = NIODeadline.now().uptimeNanoseconds
        var buffer = context.channel.allocator.buffer(capacity: 12)
        buffer.writeString("\(theTime)")

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        try await context.writeAndFlush(NIOAny(frame))
        
//        context.writeAndFlush(self.wrapOutboundOut(frame)).map {
//            context.eventLoop.scheduleTask(in: .seconds(1), { self.sendTime(context: context) })
//        }.whenFailure { (_: Error) in
//            context.close(promise: nil)
//        }
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) async throws {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            context.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
            try await context.writeAndFlush(NIOAny(closeFrame))
//            _ = context.write(self.wrapOutboundOut(closeFrame)).map { () in
//                context.close(promise: nil)
//            }
        }
    }

    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) async throws {
        var frameData = frame.data
        let maskingKey = frame.maskKey

        if let maskingKey = maskingKey {
            frameData.webSocketUnmask(maskingKey)
        }

        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        try await context.writeAndFlush(NIOAny(responseFrame))
//        context.write(self.wrapOutboundOut(responseFrame), promise: nil)
    }

    private func closeOnError(context: ChannelHandlerContext) async throws {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        try await context.writeAndFlush(NIOAny(frame))
        try await context.close(mode: .output)
//        context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
//            context.close(mode: .output, promise: nil)
//        }
        awaitingClose = true
    }
}
