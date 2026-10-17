import Foundation
import SwiftROS2Transport

/// A ``MockTransportSession`` that also lists publishers, for the umbrella's topic graph
/// tests: `publisherEndpoints()` returns `endpoints`, or throws `graphError` when set.
final class MockTopicGraphSession: MockTransportSession, TopicGraphSession, @unchecked Sendable {
    private let graphLock = NSLock()
    private var _endpoints: [GraphPublisherEndpoint] = []
    private var _graphError: TransportError?
    private var _graphCalls = 0

    var endpoints: [GraphPublisherEndpoint] {
        get { graphLock.withLock { _endpoints } }
        set { graphLock.withLock { _endpoints = newValue } }
    }

    var graphError: TransportError? {
        get { graphLock.withLock { _graphError } }
        set { graphLock.withLock { _graphError = newValue } }
    }

    var graphCalls: Int { graphLock.withLock { _graphCalls } }

    func publisherEndpoints() async throws -> [GraphPublisherEndpoint] {
        let (endpoints, error) = graphLock.withLock { () -> ([GraphPublisherEndpoint], TransportError?) in
            _graphCalls += 1
            return (_endpoints, _graphError)
        }
        if let error { throw error }
        return endpoints
    }
}
