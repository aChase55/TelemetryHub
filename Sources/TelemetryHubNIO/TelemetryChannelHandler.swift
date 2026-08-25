import Foundation
import NIOCore
import TelemetryHub

public final class TelemetryChannelHandler: ChannelDuplexHandler, Sendable {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    private let recorder: SocketRecorder

    public init(recorder: SocketRecorder) {
        self.recorder = recorder
    }

    public convenience init(
        hub: Telemetry = .shared,
        label: String,
        transport: SocketTransport = .tcp,
        tags: [String: String] = [:]
    ) {
        self.init(recorder: SocketRecorder(hub: hub, label: label, transport: transport, tags: tags))
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
        let buffer = Self.unwrapInboundIn(data)
        recorder.didReceive(bytes: buffer.readableBytes)
        context.fireChannelRead(data)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buffer = Self.unwrapOutboundIn(data)
        recorder.didSend(bytes: buffer.readableBytes)
        context.write(data, promise: promise)
    }
}

public final class TelemetryDatagramHandler: ChannelDuplexHandler, Sendable {
    public typealias InboundIn = AddressedEnvelope<ByteBuffer>
    public typealias InboundOut = AddressedEnvelope<ByteBuffer>
    public typealias OutboundIn = AddressedEnvelope<ByteBuffer>
    public typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let recorder: SocketRecorder

    public init(recorder: SocketRecorder) {
        self.recorder = recorder
    }

    public convenience init(
        hub: Telemetry = .shared,
        label: String,
        tags: [String: String] = [:]
    ) {
        self.init(recorder: SocketRecorder(hub: hub, label: label, transport: .udp, tags: tags))
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
        let envelope = Self.unwrapInboundIn(data)
        recorder.didReceive(bytes: envelope.data.readableBytes)
        context.fireChannelRead(data)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let envelope = Self.unwrapOutboundIn(data)
        recorder.didSend(bytes: envelope.data.readableBytes)
        context.write(data, promise: promise)
    }
}
