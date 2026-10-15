// RclTransportSession+Service.swift
// Service Server / Client implementation for the rcl transport.
//
// Serialize-shim design (spec §20.2/§20.4): the C bridge converts bytes to
// typed rosidl structs via rmw_deserialize / rmw_serialize and calls the typed
// rcl service API. This layer stays byte-oriented — `RclClientProtocol`
// surfaces raw CDR plus an opaque 24-byte request-id blob (server) or rcl's
// int64 sequence number (client) for correlation.

import Foundation

extension RclTransportSession {
    // TransportSession conformance (no node identity → single-node fallback).
    package func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        try createServiceServer(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, qos: qos, nodeName: nil, nodeNamespace: nil,
            handler: handler)
    }

    // NodeScopedSession conformance (node-aware creation).
    package func createServiceServer(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) throws -> any TransportService {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Service name cannot be empty")
        }
        guard !serviceTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Service type name cannot be empty")
        }
        // requestTypeHash / responseTypeHash are unused on this backend: rcl
        // derives hashes from the typesupport handle (same note as subscriber).
        let node = try preflightServiceEntity(nodeName: nodeName, nodeNamespace: nodeNamespace)
        let server = RclTransportServiceServer(client: client, name: name, handler: handler)
        let handle = try client.createServiceServer(
            node: node, srvTypeName: serviceTypeName, serviceName: name, qos: qos,
            onRequest: { [weak server] data, requestId in
                server?.handleIncomingRequest(data: data, requestId: requestId)
            })
        server.attachHandle(handle)
        try appendServiceServer(server)
        return server
    }

    // TransportSession conformance (no node identity → single-node fallback).
    package func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS
    ) throws -> any TransportClient {
        try createServiceClient(
            name: name, serviceTypeName: serviceTypeName, requestTypeHash: requestTypeHash,
            responseTypeHash: responseTypeHash, qos: qos, nodeName: nil, nodeNamespace: nil)
    }

    // NodeScopedSession conformance (node-aware creation).
    package func createServiceClient(
        name: String,
        serviceTypeName: String,
        requestTypeHash: String?,
        responseTypeHash: String?,
        qos: TransportQoS,
        nodeName: String?,
        nodeNamespace: String?
    ) throws -> any TransportClient {
        guard !name.isEmpty else {
            throw TransportError.invalidConfiguration("Service name cannot be empty")
        }
        guard !serviceTypeName.isEmpty else {
            throw TransportError.invalidConfiguration("Service type name cannot be empty")
        }
        let node = try preflightServiceEntity(nodeName: nodeName, nodeNamespace: nodeNamespace)
        let serviceClient = RclTransportServiceClient(client: client, name: name)
        let handle = try client.createServiceClient(
            node: node, srvTypeName: serviceTypeName, serviceName: name, qos: qos,
            onResponse: { [weak serviceClient] sequenceNumber, data in
                serviceClient?.handleIncomingResponse(sequenceNumber: sequenceNumber, data: data)
            })
        serviceClient.attachHandle(handle)
        try appendServiceClient(serviceClient)
        return serviceClient
    }
}

// MARK: - RCL Transport Service Server

final class RclTransportServiceServer: TransportService, @unchecked Sendable {
    private let client: any RclClientProtocol
    private var handle: (any RclServiceHandle)?
    public let name: String
    private let handler: @Sendable (Data) async throws -> Data
    private let lock = NSLock()
    private var closed = false

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        return handle?.isActive ?? false
    }

    init(
        client: any RclClientProtocol,
        name: String,
        handler: @escaping @Sendable (Data) async throws -> Data
    ) {
        self.client = client
        self.name = name
        self.handler = handler
    }

    func attachHandle(_ handle: any RclServiceHandle) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }

    /// Called from the service's wait thread (via the seam's onRequest
    /// callback). Runs the async user handler and sends the response with the
    /// same opaque request id. Detached for the same reason as the DDS wire
    /// path: the user handler must run on the global executor regardless of
    /// the C wait thread's context.
    func handleIncomingRequest(data: Data, requestId: [UInt8]) {
        let captured = (client: client, handler: handler)
        Task.detached(priority: .userInitiated) { [weak self, captured, data, requestId] in
            do {
                let userReplyCDR = try await captured.handler(data)
                // Snapshot the handle after the handler completes so a server
                // closed mid-handler drops the response instead of racing.
                guard let self, let h = self.handleSnapshot() else { return }
                try? captured.client.sendResponse(h, requestId: requestId, data: userReplyCDR)
            } catch {
                // User handler threw — mirror the wire path
                // (DDSTransportSession+Service): best-effort drop, no reply.
                _ = error
            }
        }
    }

    private func handleSnapshot() -> (any RclServiceHandle)? {
        lock.lock()
        defer { lock.unlock() }
        return closed ? nil : handle
    }

    public func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let h = handle
        handle = nil
        lock.unlock()
        if let h {
            // Blocks until any in-flight onRequest invocation has returned.
            client.destroyServiceServer(h)
        }
    }
}

// MARK: - RCL Transport Service Client

final class RclTransportServiceClient: TransportClient, @unchecked Sendable {
    private let client: any RclClientProtocol
    private var handle: (any RclClientHandle)?
    public let name: String
    private let lock = NSLock()
    private var closed = false
    private let pending = RclPendingCallTable()

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        return handle?.isActive ?? false
    }

    init(client: any RclClientProtocol, name: String) {
        self.client = client
        self.name = name
    }

    func attachHandle(_ handle: any RclClientHandle) {
        lock.lock()
        self.handle = handle
        lock.unlock()
    }

    public func waitForService(timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            lock.lock()
            let h = closed ? nil : handle
            lock.unlock()
            if let h, client.serverAvailable(h) {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
        }
        throw TransportError.requestTimeout(timeout)
    }

    public func call(requestCDR: Data, timeout: Duration) async throws -> Data {
        guard requestCDR.count >= 4 else {
            throw TransportError.invalidConfiguration("requestCDR missing 4-byte CDR encapsulation header")
        }

        lock.lock()
        let handleOpt = closed ? nil : handle
        lock.unlock()
        guard let h = handleOpt else {
            throw TransportError.sessionClosed
        }

        let rclClient = client
        return try await rclAwaitCorrelatedReply(table: pending, timeout: timeout) {
            try rclClient.sendRequest(h, data: requestCDR)
        }
    }

    /// Called from the client's wait thread (via the seam's onResponse
    /// callback). Hop to a Task before touching the pending table so the wait
    /// thread never blocks on the table lock — `close()` joins that thread
    /// while other threads may hold the lock.
    func handleIncomingResponse(sequenceNumber: Int64, data: Data) {
        let table = pending
        Task { [table] in
            table.resolve(seq: sequenceNumber, with: .success(data))
        }
    }

    public func close() throws {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let h = handle
        handle = nil
        lock.unlock()

        pending.failAll(TransportError.sessionClosed)

        if let h {
            // Blocks until any in-flight onResponse invocation has returned.
            client.destroyServiceClient(h)
        }
    }
}

// MARK: - Correlated request/response park

/// Park a continuation in `table`, run `send` (which returns rcl's sequence
/// number — the correlation key), and await the matching reply, the timeout,
/// or task cancellation. Shared by the service client and the action
/// client (per role table).
///
/// registerAndSend holds the table lock across the send, so a response
/// arriving immediately after rcl's send blocks on the same lock until the
/// continuation is registered — no response-before-registration race. (The
/// response path hops off the wait thread via a Task before taking the lock,
/// so the destroy-join can never deadlock against it.)
func rclAwaitCorrelatedReply(
    table: RclPendingCallTable,
    timeout: Duration,
    send: @escaping () throws -> Int64
) async throws -> Data {
    let state = RclCallState()
    do {
        let body: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                let seq = table.registerAndSend(cont, send: send)
                guard let seq else { return }  // resumed with the send error
                state.setSequence(seq)
                // Cancellation may have fired before the sequence number was
                // known; settle it now.
                if Task.isCancelled {
                    table.resolve(seq: seq, with: .failure(TransportError.requestCancelled))
                    return
                }
                // A caller-supplied timeout large enough to overflow
                // `Task.sleep`'s internal nanosecond conversion (e.g.
                // `.seconds(Int.max)`, used as "no timeout") must not be
                // handed to `Task.sleep` — skip starting the timeout task
                // entirely and wait indefinitely instead.
                guard isSafeSleepDuration(timeout) else { return }
                state.setTimeoutTask(
                    Task { [table] in
                        // If the sleep is cancelled (reply arrived first),
                        // exit without resolving — same contract as the DDS
                        // wire path's timeout helper.
                        do {
                            try await Task.sleep(for: timeout)
                        } catch {
                            return
                        }
                        table.resolve(seq: seq, with: .failure(TransportError.requestTimeout(timeout)))
                    })
            }
        } onCancel: {
            if let seq = state.sequence {
                table.resolve(seq: seq, with: .failure(TransportError.requestCancelled))
            }
        }
        state.timeoutTask?.cancel()
        return body
    } catch {
        state.timeoutTask?.cancel()
        throw error
    }
}

// MARK: - Pending-call correlation

/// Lock-guarded continuation table keyed by rcl's sequence number.
///
/// Unlike the DDS path (which picks its own sequence numbers up front and can
/// register before writing), rcl assigns the sequence number inside
/// `rcl_send_request` — so `registerAndSend` holds the lock across the send
/// and the registration as one atomic step. The response side takes the same
/// lock in `resolve`, which makes a response observed between send and
/// registration impossible.
///
/// The table is close-aware: `failAll` latches `isClosed` under the lock, and
/// a `registerAndSend` that loses the race against `close()` (snapshot read
/// before close, registration after `failAll`'s sweep) resumes promptly with
/// `sessionClosed` instead of parking a continuation nobody will sweep.
/// Internal (not private) so the close-race unit test can drive it directly.
final class RclPendingCallTable: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int64: CheckedContinuation<Data, Error>] = [:]
    private var isClosed = false

    /// Runs `send` and registers `cont` under the returned sequence number
    /// while holding the lock. Returns the sequence number on success; on a
    /// send failure the continuation is resumed with the thrown error and nil
    /// is returned. If `failAll` already ran, the continuation is resumed
    /// with `sessionClosed` without sending.
    func registerAndSend(
        _ cont: CheckedContinuation<Data, Error>,
        send: () throws -> Int64
    ) -> Int64? {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            cont.resume(throwing: TransportError.sessionClosed)
            return nil
        }
        do {
            let seq = try send()
            pending[seq] = cont
            lock.unlock()
            return seq
        } catch {
            lock.unlock()
            cont.resume(throwing: error)
            return nil
        }
    }

    @discardableResult
    func resolve(seq: Int64, with result: Result<Data, Error>) -> Bool {
        lock.lock()
        let cont = pending.removeValue(forKey: seq)
        lock.unlock()
        cont?.resume(with: result)
        return cont != nil
    }

    func failAll(_ error: Error) {
        lock.lock()
        isClosed = true
        let snapshot = pending
        pending.removeAll()
        lock.unlock()
        for (_, cont) in snapshot {
            cont.resume(throwing: error)
        }
    }
}

/// Mutable call-scoped state shared between the continuation body, the
/// timeout helper, and the cancellation handler.
private final class RclCallState: @unchecked Sendable {
    private let lock = NSLock()
    private var _sequence: Int64?
    private var _timeoutTask: Task<Void, Never>?

    var sequence: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return _sequence
    }

    var timeoutTask: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return _timeoutTask
    }

    func setSequence(_ seq: Int64) {
        lock.lock()
        _sequence = seq
        lock.unlock()
    }

    func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        _timeoutTask = task
        lock.unlock()
    }
}
