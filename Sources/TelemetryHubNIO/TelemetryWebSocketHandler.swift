import Foundation
import NIOCore
import NIOWebSocket
import TelemetryHub
import os

public final class TelemetryWebSocketHandler: ChannelDuplexHandler, Sendable {
    public typealias InboundIn = WebSocketFrame
    public typealias InboundOut = WebSocketFrame
    public typealias OutboundIn = WebSocketFrame
    public typealias OutboundOut = WebSocketFrame

    private let recorder: SocketRecorder
    private let pingTimes = OSAllocatedUnfairLock(initialState: [Date]())

    public init(recorder: SocketRecorder) {
        self.recorder = recorder
    }

    public convenience init(
        hub: Telemetry = .shared,
        label: String,
        tags: [String: String] = [:]
    ) {
        self.init(recorder: SocketRecorder(hub: hub, label: label, transport: .webSocket, tags: tags))
    }

    public func channelActive(context: ChannelHandlerContext) {
        recorder.didConnect()
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        recorder.didDisconnect()
        context.fireChannelInactive()
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        recorder.didDisconnect(error: error)
        context.fireErrorCaught(error)
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary, .continuation:
            recorder.didReceive(bytes: frame.data.readableBytes)
        case .pong:
            let sent = pingTimes.withLock { times -> Date? in
                times.isEmpty ? nil : times.removeFirst()
            }
            if let sent {
                recorder.didMeasureRoundTrip(milliseconds: Date().timeIntervalSince(sent) * 1000)
            }
        default:
            break
        }
        context.fireChannelRead(data)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = Self.unwrapOutboundIn(data)
        switch frame.opcode {
        case .text, .binary, .continuation:
            recorder.didSend(bytes: frame.data.readableBytes)
        case .ping:
            pingTimes.withLock { $0.append(Date()) }
        default:
            break
        }
        context.write(data, promise: promise)
    }
}
