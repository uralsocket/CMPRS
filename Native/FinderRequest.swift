import Foundation
import Darwin

struct FinderRequest {
    let mode: CompressionMode?
    let container: ContainerFormat?
    let inputs: [URL]
    static let fileExtension = "cmprsrequest"

    static func read(_ url: URL) throws -> FinderRequest {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 4_000_000 else { throw NativeFailure("Invalid Finder request.") }
        let data = try Data(contentsOf: url)
        guard let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              object["version"] as? Int == 1,
              object["source"] as? String == "com.glebkaravaev.cmprs.finder",
              let paths = object["files"] as? [String], !paths.isEmpty, paths.count <= 10_000 else { throw NativeFailure("Invalid Finder request.") }
        let mode: CompressionMode?
        if let value = object["mode"] as? String { guard let choice = CompressionMode(rawValue: value) else { throw NativeFailure("Unknown Finder compression mode.") }; mode = choice } else { mode = nil }
        let container: ContainerFormat?
        if let value = object["container"] as? String { guard let choice = ContainerFormat(rawValue: value) else { throw NativeFailure("Unknown Finder file format.") }; container = choice } else { container = nil }
        guard mode != nil || container != nil else { throw NativeFailure("Finder action has no preset.") }
        var inputs: [URL] = []
        for path in paths {
            guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 32_768 else { throw NativeFailure("Invalid video path in Finder request.") }
            let input = URL(fileURLWithPath: path).standardizedFileURL
            guard input.pathExtension.lowercased() != fileExtension else { throw NativeFailure("Nested Finder requests are not supported.") }
            if !inputs.contains(input) { inputs.append(input) }
        }
        return FinderRequest(mode: mode, container: container, inputs: inputs)
    }

    // Only consume the private temporary envelope created by our own action.
    // rmdir removes an empty directory and never recursively removes contents.
    static func consumeTemporary(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        guard url.lastPathComponent == "Selection." + fileExtension,
              parent.lastPathComponent.hasPrefix("cmprs-request."),
              let info = try? FileManager.default.attributesOfItem(atPath: parent.path),
              info[.type] as? FileAttributeType == .typeDirectory,
              (info[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (info[.posixPermissions] as? NSNumber)?.intValue == 0o700 else { return }
        try? FileManager.default.removeItem(at: url)
        _ = rmdir(parent.path)
    }
}
