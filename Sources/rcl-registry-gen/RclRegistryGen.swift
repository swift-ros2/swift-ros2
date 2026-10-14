import ArgumentParser
import Foundation
import SwiftROS2Gen

/// Regenerates CRclBridge's name-keyed type-support registries from type-name lists.
@main
struct RclRegistryGen: ParsableCommand {
    @Option(help: "Comma-separated message names (pkg/msg/Type) resolvable on the RCL backend.")
    var msgTypes: String

    @Option(help: "Comma-separated service names (pkg/srv/Type).")
    var srvTypes: String

    @Option(help: "Comma-separated action names (pkg/action/Type).")
    var actionTypes: String

    @Option(
        help:
            "<package>=<directory>. Repeatable. The IDL package holding action/<Type>.action for an --action-types entry; its Result is checked against the GetResult splice constraint."
    )
    var actionIdl: [String] = []

    @Option(help: "CRclBridge source root, e.g. Sources/CRclBridge.")
    var cOutput: String

    func run() throws {
        func list(_ csv: String) -> [String] { csv.split(separator: ",").map(String.init) }
        let services = try list(srvTypes).map { name -> CSrvRegistryEmitter.ServiceRef in
            let (package, typeName) = try split(name, kind: "srv")
            return CSrvRegistryEmitter.ServiceRef(package: package, typeName: typeName)
        }
        let actions = try list(actionTypes).map { name -> CActionRegistryEmitter.ActionRef in
            let (package, typeName) = try split(name, kind: "action")
            return CActionRegistryEmitter.ActionRef(package: package, typeName: typeName)
        }
        try checkResultSplice(actions)
        let root = URL(fileURLWithPath: cOutput, isDirectory: true)
        let files: [(path: String, contents: String)] = [
            ("Generated/crcl_marshal_registry.c", MsgRegistryEmitter.emitRegistry(list(msgTypes))),
            ("include/crcl_marshal.h", MsgRegistryEmitter.emitHeader()),
            ("Generated/crcl_srv_registry.c", CSrvRegistryEmitter.emit(services)),
            ("include/Generated/crcl_srv_registry.h", CSrvRegistryEmitter.emitHeader(services)),
            ("Generated/crcl_action_registry.c", CActionRegistryEmitter.emit(actions)),
            ("include/Generated/crcl_action_registry.h", CActionRegistryEmitter.emitHeader(actions)),
        ]
        for file in files {
            let url = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Splits `<package>/<kind>/<Type>`.
    private func split(_ name: String, kind: String) throws -> (String, String) {
        let parts = name.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[1] == kind, !parts[0].isEmpty, !parts[2].isEmpty else {
            throw ValidationError("expected <package>/\(kind)/<Type>, got '\(name)'")
        }
        return (parts[0], parts[2])
    }

    /// 2.3.2's GetResult splice guard: the action byte seam splices the Result body at CDR
    /// offset 4, so a Result whose first field needs 8-byte alignment is rejected here. A
    /// nested first field is resolved only against the action's own Goal / Result / Feedback
    /// and is otherwise rejected (conservative, as in 2.3.2).
    private func checkResultSplice(_ actions: [CActionRegistryEmitter.ActionRef]) throws {
        var directories: [String: URL] = [:]
        for raw in actionIdl {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[0].isEmpty else {
                throw ValidationError("invalid --action-idl '\(raw)' — expected <package>=<directory>")
            }
            directories[parts[0]] = URL(fileURLWithPath: parts[1], isDirectory: true)
        }
        for action in actions {
            guard let directory = directories[action.package] else {
                throw ValidationError("\(action.rosName): pass --action-idl \(action.package)=<directory>")
            }
            let parsed = try Pipeline.parseActionsIn(
                run: Pipeline.PackageRun(
                    input: PackageInput(name: action.package, directory: directory),
                    typesAllowList: [action.typeName]))
            guard let ir = parsed.first(where: { $0.typeName == action.typeName })?.actionIR else {
                throw ValidationError("\(action.rosName): no action/\(action.typeName).action in \(directory.path)")
            }
            let registry = Dictionary(
                uniqueKeysWithValues: [ir.goal, ir.result, ir.feedback].map { ($0.rosTypeName, $0) })
            if let violation = CActionRegistryEmitter.resultSpliceViolation(
                action: action, result: ir.result, registry: registry)
            {
                throw ValidationError(violation)
            }
        }
    }
}
