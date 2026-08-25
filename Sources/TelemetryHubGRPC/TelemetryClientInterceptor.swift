import Foundation
import GRPCCore
import TelemetryHub
import os

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public struct TelemetryClientInterceptor: ClientInterceptor {
    private let recorder: NetworkRequestRecorder

    public init(hub: Telemetry = .shared, tags: [String: String] = [:]) {
        self.recorder = NetworkRequestRecorder(hub: hub, kind: .grpcCall, tags: tags)
    }

    public func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        let token = recorder.begin(name: context.descriptor.fullyQualifiedMethod)
        let recorder = self.recorder

        let response: StreamingClientResponse<Output>
        do {
            response = try await next(request, context)
        } catch {
            recorder.end(token, status: .error(String(describing: error)))
            throw error
        }

        switch response.accepted {
        case .failure(let rpcError):
            recorder.end(
                token,
                status: .error(rpcError.message),
                tags: ["grpc_code": String(describing: rpcError.code)]
            )
            return response
        case .success(var contents):
            let observed = TerminationObservingSequence(base: contents.bodyParts) { error in
                if let rpcError = error as? RPCError {
                    recorder.end(
                        token,
                        status: .error(rpcError.message),
                        tags: ["grpc_code": String(describing: rpcError.code)]
                    )
                } else if error is CancellationError {
                    recorder.end(token, status: .error("cancelled"), tags: ["grpc_code": "cancelled"])
                } else if let error {
                    recorder.end(token, status: .error(String(describing: error)))
                } else {
                    recorder.end(token, status: .ok, tags: ["grpc_code": "ok"])
                }
            }
            contents.bodyParts = RPCAsyncSequence(wrapping: observed)
            var response = response
            response.accepted = .success(contents)
            return response
        }
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
final class TerminationSentinel: Sendable {
    private let onTermination: @Sendable ((any Error)?) -> Void
    private let didTerminate = OSAllocatedUnfairLock(initialState: false)

    init(onTermination: @escaping @Sendable ((any Error)?) -> Void) {
        self.onTermination = onTermination
    }

    func terminate(_ error: (any Error)?) {
        let isFirst = didTerminate.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        if isFirst {
            onTermination(error)
        }
    }

    deinit {
        terminate(CancellationError())
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
struct TerminationObservingSequence<Element: Sendable>: AsyncSequence, Sendable {
    let base: RPCAsyncSequence<Element, any Error>
    let sentinel: TerminationSentinel

    init(base: RPCAsyncSequence<Element, any Error>, onTermination: @escaping @Sendable ((any Error)?) -> Void) {
        self.base = base
        self.sentinel = TerminationSentinel(onTermination: onTermination)
    }

    func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), sentinel: sentinel)
    }

    struct Iterator: AsyncIteratorProtocol {
        var base: RPCAsyncSequence<Element, any Error>.AsyncIterator
        let sentinel: TerminationSentinel

        mutating func next() async throws -> Element? {
            do {
                if let element = try await base.next() {
                    return element
                }
                sentinel.terminate(nil)
                return nil
            } catch {
                sentinel.terminate(error)
                throw error
            }
        }
    }
}
