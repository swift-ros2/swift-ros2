// ActionTypes.swift
// Public enums for the ROS 2 Actions umbrella API.

import Foundation

/// Server-side decision for `ActionServerHandler.handleGoal`.
public enum GoalResponse: Sendable, Equatable {
    case accept
    case reject
}

/// Server-side decision for `ActionServerHandler.handleCancel`.
public enum CancelResponse: Sendable, Equatable {
    case accept
    case reject
}

/// `action_msgs/msg/GoalStatus` raw values exposed to user code.
///
/// Named `ActionGoalStatus` to avoid colliding with the wire-level
/// `ActionMsgs.GoalStatus` struct (the embedded CDR payload of
/// `GoalStatusArray`). Both are re-exported through the umbrella.
public enum ActionGoalStatus: Int8, Sendable, Equatable, CaseIterable {
    case unknown = 0
    case accepted = 1
    case executing = 2
    case canceling = 3
    case succeeded = 4
    case canceled = 5
    case aborted = 6

    /// Whether this is a terminal state — true means the goal is finished and
    /// the per-goal feedback / status streams will close after this value.
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .canceled, .aborted: return true
        default: return false
        }
    }
}

/// Result of awaiting an action goal's terminal state.
///
/// Call `await handle.result()` to await this.
public enum ActionResult<R: Sendable>: Sendable {
    case succeeded(R)
    case aborted(reason: String?)
    case canceled
}

/// Errors thrown by the action umbrella API.
public enum ActionError: Error, LocalizedError, Sendable {
    case actionServerUnavailable
    case goalRejected
    case goalCanceled
    case goalAborted(reason: String?)
    case acceptanceTimedOut
    case resultTimedOut
    case cancelRejected
    case wrongSide
    case clientClosed
    case serverClosed
    case requestEncodingFailed(String)
    case responseDecodingFailed(String)
    case mapping(Error)

    public var errorDescription: String? {
        switch self {
        case .actionServerUnavailable: return "Action server is not reachable"
        case .goalRejected: return "Action goal was rejected by the server"
        case .goalCanceled: return "Action goal was canceled"
        case .goalAborted(let r): return "Action goal was aborted\(r.map { ": \($0)" } ?? "")"
        case .acceptanceTimedOut: return "Action goal acceptance timed out"
        case .resultTimedOut: return "Action goal result timed out"
        case .cancelRejected: return "Action cancel request was rejected"
        case .wrongSide:
            return "Operation is not valid on this side (e.g. publishFeedback called on a client-side handle)"
        case .clientClosed: return "Action client is closed"
        case .serverClosed: return "Action server is closed"
        case .requestEncodingFailed(let m): return "Encoding failed: \(m)"
        case .responseDecodingFailed(let m): return "Decoding failed: \(m)"
        case .mapping(let e): return "Underlying error: \(e)"
        }
    }
}
