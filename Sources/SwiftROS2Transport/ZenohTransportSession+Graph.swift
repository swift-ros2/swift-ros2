// ZenohTransportSession+Graph.swift
// The topic graph of a wire Zenoh session: the publishers rmw_zenoh_cpp announces.

import Foundation
import SwiftROS2Wire

extension ZenohTransportSession: TopicGraphSession {
    /// Every publisher of the domain, read from the `MP` liveliness tokens.
    ///
    /// One liveliness query per call on `@ros2_lv/<domain>/*/*/*/MP/**`, answered by the
    /// router, merged with the session's own publisher tokens and deduplicated by token.
    /// Tokens that do not parse are skipped. A call waits at most
    /// ``graphLimits``'s deadline and either returns the full answer or throws; see
    /// ``ZenohGraphLimits`` for the single flight and the stalled-query budget.
    ///
    /// - Throws: ``TransportError/notConnected`` when the session is closed or has lost
    ///   its router; ``TransportError/sessionUnhealthy(_:)`` when the router does not
    ///   answer in time, the query fails, a timed-out query is still pending, or the
    ///   session is graph-stalled.
    package func publisherEndpoints() async throws -> [GraphPublisherEndpoint] {
        let (config, codec) = try openState()
        let keyExpr = codec.makePublisherLivelinessQuery(domainId: config.domainId)
        let timeoutMs = graphLimits.deadline.zenohQueryTimeoutMs
        let client = self.client
        let remote = try await graphQueries.tokens { onReply, onFinish in
            try client.livelinessGet(
                keyExpr: keyExpr,
                timeoutMs: timeoutMs,
                handler: { result in
                    if case .success(let sample) = result { onReply(sample.keyExpr) }
                },
                onFinish: onFinish)
        }
        let tokens = Set(remote).union(ownPublisherTokens.snapshot)
        return tokens.compactMap { token in
            ZenohWireCodec.parsePublisherToken(token).map(GraphPublisherEndpoint.init(zenohToken:))
        }
    }
}

extension GraphPublisherEndpoint {
    init(zenohToken info: ZenohPublisherTokenInfo) {
        self.init(
            topicName: info.topicName,
            typeName: info.typeName,
            reliability: info.reliability == .reliable ? .reliable : .bestEffort,
            durability: info.durability == .transientLocal ? .transientLocal : .volatile,
            nodeName: info.nodeName,
            nodeNamespace: info.nodeNamespace)
    }
}
