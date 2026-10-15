// Per-node parameter storage: declare / get / set / list / describe with
// validation. Services and ParameterEvent publishing are layered on top in
// Node+ParameterServices.swift.

import Foundation
import SwiftROS2Messages

struct ParameterEntry: Sendable, Equatable {
    var value: ROS2ParameterValue
    var descriptor: ROS2ParameterDescriptor
}

actor ParameterStore {
    private var entries: [String: ParameterEntry] = [:]
    private var servicesStarted = false

    // Callback registries, keyed by a monotonic id. Stored as ordered
    // arrays (id, closure) so we can iterate in registration order.
    // Unregister-by-handle is linear in the registry size; the registries
    // typically hold a handful of callbacks, so the constant factor wins
    // over a dictionary plus a separate ordering structure.
    private typealias PreSetCallback = @Sendable (inout [ROS2Parameter]) -> Void
    private typealias OnSetCallback = @Sendable ([ROS2Parameter]) -> ROS2SetParametersResult
    private typealias PostSetCallback = @Sendable ([ROS2Parameter]) -> Void

    private var preSetCallbacks: [(id: UInt64, fn: PreSetCallback)] = []
    private var onSetCallbacks: [(id: UInt64, fn: OnSetCallback)] = []
    private var postSetCallbacks: [(id: UInt64, fn: PostSetCallback)] = []
    private var nextCallbackId: UInt64 = 1

    private var eventEmitter: (@Sendable (ParameterEvent) -> Void)?

    init() {}

    @discardableResult
    func declare(
        name: String,
        value: ROS2ParameterValue,
        descriptor: ROS2ParameterDescriptor
    ) throws -> ROS2ParameterValue {
        guard entries[name] == nil else {
            throw ROS2ParameterError.alreadyDeclared(name: name)
        }
        // Validate the initial value against the descriptor — the same rules
        // that gate set(_:) apply at declare time. readOnly is intentionally
        // skipped here: declare IS the one legal write to a read-only param.
        if let reason = validate(
            name: name, value: value, descriptor: descriptor, allowWriteToReadOnly: true)
        {
            throw ROS2ParameterError.invalidValue(name: name, reason: reason)
        }
        entries[name] = ParameterEntry(value: value, descriptor: descriptor)
        emitNew([ROS2Parameter(name: name, value: value)])
        return value
    }

    func undeclare(name: String) throws {
        guard let removed = entries.removeValue(forKey: name) else {
            throw ROS2ParameterError.notDeclared(name: name)
        }
        emitDeleted([ROS2Parameter(name: name, value: removed.value)])
    }

    func has(name: String) -> Bool {
        entries[name] != nil
    }
}

extension ParameterStore {
    func get(name: String) throws -> ROS2Parameter {
        guard let e = entries[name] else {
            throw ROS2ParameterError.notDeclared(name: name)
        }
        return ROS2Parameter(name: name, value: e.value)
    }

    func describe(name: String) throws -> ROS2ParameterDescriptor {
        guard let e = entries[name] else {
            throw ROS2ParameterError.notDeclared(name: name)
        }
        return e.descriptor
    }

    func list(prefixes: [String], depth: UInt64) -> ROS2ListParametersResult {
        let allNames = entries.keys.sorted()
        let matched: [String]
        if prefixes.isEmpty {
            matched = allNames.filter { passesDepth($0, prefix: "", depth: depth) }
        } else {
            matched = allNames.filter { name in
                prefixes.contains { p in
                    (name == p || name.hasPrefix(p + "."))
                        && passesDepth(name, prefix: p, depth: depth)
                }
            }
        }
        let derivedPrefixes = collectPrefixes(matched)
        return ROS2ListParametersResult(names: matched, prefixes: derivedPrefixes)
    }

    private func passesDepth(_ name: String, prefix: String, depth: UInt64) -> Bool {
        if depth == 0 { return true }
        let suffix: Substring
        if prefix.isEmpty {
            suffix = name[...]
        } else if name == prefix {
            return true
        } else {
            suffix = name.dropFirst(prefix.count + 1)  // skip "<prefix>."
        }
        // Stay in UInt64-land so a depth > Int.max can't trap on the cast.
        let separators = UInt64(suffix.filter { $0 == "." }.count)
        return separators < depth
    }

    private func collectPrefixes(_ names: [String]) -> [String] {
        var seen = Set<String>()
        for name in names {
            var parts = name.split(separator: ".", omittingEmptySubsequences: false)
            // every proper ancestor (drop the last segment, then the next, ...)
            while parts.count > 1 {
                parts.removeLast()
                seen.insert(parts.joined(separator: "."))
            }
        }
        return seen.sorted()
    }
}

extension ParameterStore {
    @discardableResult
    func set(_ p: ROS2Parameter) -> ROS2SetParametersResult {
        let results = setMany([p])
        return results.first ?? .failure(reason: "no result")
    }

    func setMany(_ ps: [ROS2Parameter]) -> [ROS2SetParametersResult] {
        // Pre-set runs once on the full proposed list and may mutate it
        // (inject co-dependent params, rewrite values, drop entries). The
        // possibly-grown list is what we then iterate — so pre-set
        // injections are not lost.
        var batch = ps
        for cb in preSetCallbacks { cb.fn(&batch) }

        // Per-item descriptor validation. Failures are recorded individually
        // and don't short-circuit the batch.
        var results = Array(repeating: ROS2SetParametersResult.success(), count: batch.count)
        var passingIndices: [Int] = []
        for (i, p) in batch.enumerated() {
            guard let entry = entries[p.name] else {
                results[i] = .failure(reason: "parameter '\(p.name)' is not declared")
                continue
            }
            if let reason = validate(
                name: p.name, value: p.value, descriptor: entry.descriptor,
                allowWriteToReadOnly: false)
            {
                results[i] = .failure(reason: reason)
                continue
            }
            passingIndices.append(i)
        }

        guard !passingIndices.isEmpty else { return results }

        // On-set runs once on the items that cleared validation. A veto
        // marks every passing slot as failed and skips the writes — this
        // lets a callback enforce cross-parameter invariants for the call.
        let candidates = passingIndices.map { batch[$0] }
        for cb in onSetCallbacks {
            let r = cb.fn(candidates)
            if !r.successful {
                for i in passingIndices { results[i] = r }
                return results
            }
        }

        // Apply the writes for every passing item.
        var applied: [ROS2Parameter] = []
        for i in passingIndices {
            let p = batch[i]
            guard var entry = entries[p.name] else { continue }
            entry.value = p.value
            entries[p.name] = entry
            applied.append(p)
        }
        if !applied.isEmpty {
            for cb in postSetCallbacks { cb.fn(applied) }
            emitChanged(applied)
        }
        return results
    }

    func setAtomically(_ ps: [ROS2Parameter]) -> ROS2SetParametersResult {
        var batch = ps
        for cb in preSetCallbacks { cb.fn(&batch) }
        // Validate every item against its descriptor first; any failure
        // aborts the batch with the offending reason.
        for p in batch {
            guard let entry = entries[p.name] else {
                return .failure(reason: "parameter '\(p.name)' is not declared")
            }
            if let reason = validate(
                name: p.name, value: p.value, descriptor: entry.descriptor,
                allowWriteToReadOnly: false)
            {
                return .failure(reason: reason)
            }
        }
        // On-set chain: first failure short-circuits the whole batch.
        for cb in onSetCallbacks {
            let r = cb.fn(batch)
            if !r.successful { return r }
        }
        // Snapshot for safe rollback (defensive — validation passed for every
        // item, so the writes should never throw).
        let snapshot = entries
        for p in batch {
            guard var entry = entries[p.name] else {
                entries = snapshot
                return .failure(reason: "parameter '\(p.name)' disappeared mid-batch")
            }
            entry.value = p.value
            entries[p.name] = entry
        }
        for cb in postSetCallbacks { cb.fn(batch) }
        emitChanged(batch)
        return .success()
    }

    /// Returns nil if the value is acceptable, otherwise a human-readable reason.
    ///
    /// `floatingPointStep` and `integerStep` from the descriptor are NOT
    /// enforced here — they are advisory metadata for tools (rqt_param,
    /// `ros2 param describe`). rclcpp follows the same convention.
    private func validate(
        name: String,
        value: ROS2ParameterValue,
        descriptor: ROS2ParameterDescriptor,
        allowWriteToReadOnly: Bool
    ) -> String? {
        if descriptor.readOnly && !allowWriteToReadOnly {
            return "parameter '\(name)' is read-only"
        }
        let valueType = value.parameterType
        if !descriptor.dynamicTyping
            && descriptor.type != .notSet
            && valueType != descriptor.type
            && valueType != .notSet
        {
            return "parameter '\(name)' expects \(descriptor.type), got \(valueType)"
        }
        if case .integer(let v) = value, let r = descriptor.integerRange {
            if v < r.lowerBound || v > r.upperBound {
                return "parameter '\(name)' value \(v) out of range \(r)"
            }
        }
        if case .double(let v) = value, let r = descriptor.floatingPointRange {
            if v < r.lowerBound || v > r.upperBound {
                return "parameter '\(name)' value \(v) out of range \(r)"
            }
        }
        return nil
    }
}

extension ParameterStore {
    /// Non-throwing accessor used by the parameter-service handlers. The
    /// throwing variants (`get`, `describe`) keep the rclcpp convention
    /// for direct Swift callers; the wire services prefer to encode an
    /// "absent" answer rather than surface an error to the caller.
    func entry(name: String) -> (value: ROS2ParameterValue, descriptor: ROS2ParameterDescriptor)? {
        guard let e = entries[name] else { return nil }
        return (e.value, e.descriptor)
    }

    /// One-shot latch used by `Node.startParameterServices()` to claim
    /// the right to register the six parameter services. Returns `true`
    /// the first time it is called; subsequent calls return `false`.
    ///
    /// The latch is claimed *before* the six `createService` calls so
    /// concurrent `startParameterServices()` invocations can't double-
    /// register. If registration then fails partway through, the caller
    /// must invoke `resetServicesStarted()` so a future retry can
    /// re-claim the latch.
    @discardableResult
    func markServicesStarted() -> Bool {
        if servicesStarted { return false }
        servicesStarted = true
        return true
    }

    /// Release the latch so a future `startParameterServices()` call can
    /// re-claim it. Called by `Node.startParameterServices()` when one of
    /// the six `createService` registrations throws — the partially-
    /// registered services are torn down by `Node.destroy()` (or by the
    /// caller's own cleanup) and the node is left in an un-started state.
    func resetServicesStarted() {
        servicesStarted = false
    }
}

extension ParameterStore {
    func registerPreSet(
        _ cb: @escaping @Sendable (inout [ROS2Parameter]) -> Void
    ) -> ROS2ParameterCallbackHandle {
        let id = nextCallbackId
        nextCallbackId &+= 1
        preSetCallbacks.append((id, cb))
        return ROS2ParameterCallbackHandle(id: id)
    }

    func registerOnSet(
        _ cb: @escaping @Sendable ([ROS2Parameter]) -> ROS2SetParametersResult
    ) -> ROS2ParameterCallbackHandle {
        let id = nextCallbackId
        nextCallbackId &+= 1
        onSetCallbacks.append((id, cb))
        return ROS2ParameterCallbackHandle(id: id)
    }

    func registerPostSet(
        _ cb: @escaping @Sendable ([ROS2Parameter]) -> Void
    ) -> ROS2ParameterCallbackHandle {
        let id = nextCallbackId
        nextCallbackId &+= 1
        postSetCallbacks.append((id, cb))
        return ROS2ParameterCallbackHandle(id: id)
    }

    /// Returns `true` if a callback with that handle was found and removed,
    /// `false` if no such handle was registered (or it had already been
    /// removed). Idempotent — repeated calls are safe.
    @discardableResult
    func unregisterCallback(_ handle: ROS2ParameterCallbackHandle) -> Bool {
        if let idx = preSetCallbacks.firstIndex(where: { $0.id == handle.id }) {
            preSetCallbacks.remove(at: idx)
            return true
        }
        if let idx = onSetCallbacks.firstIndex(where: { $0.id == handle.id }) {
            onSetCallbacks.remove(at: idx)
            return true
        }
        if let idx = postSetCallbacks.firstIndex(where: { $0.id == handle.id }) {
            postSetCallbacks.remove(at: idx)
            return true
        }
        return false
    }

    func setEventEmitter(
        _ emitter: (@Sendable (ParameterEvent) -> Void)?
    ) {
        self.eventEmitter = emitter
    }
}

extension ParameterStore {
    /// Build a `ParameterEvent` from per-bucket lists and fan it out via the
    /// installed emitter (if any). The `node` field is filled by the emitter
    /// closure on the Node side — the store doesn't know its own FQN.
    private func emit(
        new: [ROS2Parameter] = [],
        changed: [ROS2Parameter] = [],
        deleted: [ROS2Parameter] = []
    ) {
        guard let emitter = eventEmitter else { return }
        guard !(new.isEmpty && changed.isEmpty && deleted.isEmpty) else { return }
        let now = nowAsTime()
        let event = ParameterEvent(
            stamp: now,
            node: "",  // filled in by the Node-side emitter wrapper
            newParameters: new.map { $0.toWire() },
            changedParameters: changed.map { $0.toWire() },
            deletedParameters: deleted.map { $0.toWire() }
        )
        emitter(event)
    }

    func emitChanged(_ params: [ROS2Parameter]) { emit(changed: params) }
    func emitNew(_ params: [ROS2Parameter]) { emit(new: params) }
    func emitDeleted(_ params: [ROS2Parameter]) { emit(deleted: params) }

    private func nowAsTime() -> Time {
        let sec = Date().timeIntervalSince1970
        // builtin_interfaces/Time.sec is `int32`. Clamping (rather than
        // converting) keeps long-lived nodes from trapping past Y2038 — the
        // resulting timestamp is wrong, but the node stays up. ROS itself
        // is going to have to deal with the overflow upstream regardless.
        let clamped = min(max(sec, Double(Int32.min)), Double(Int32.max))
        let secInt = Int32(clamped)
        let frac = clamped - Double(secInt)
        let nanos = UInt32(min(max(frac * 1_000_000_000, 0.0), 999_999_999.0))
        return Time(sec: secInt, nanosec: nanos)
    }
}
