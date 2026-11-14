import ArgumentParser
import Foundation

/// Regenerates CRclBridge's name-keyed type-support registries from type-name lists.
@main
struct RclRegistryGen: ParsableCommand {
    @Option(help: "Comma-separated message names (pkg/msg/Type) resolvable on the RCL backend.")
    var msgTypes: String

    @Option(help: "Comma-separated service names (pkg/srv/Type).")
    var srvTypes: String

    @Option(help: "Comma-separated action names (pkg/action/Type).")
    var actionTypes: String

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
}
