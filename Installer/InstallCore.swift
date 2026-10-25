import Foundation

struct SetupFailure: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
struct InstallCore {
    let home: URL
    let app: URL
    let verifyApp: (URL) throws -> Void
    let checkpoint: (Int) throws -> Void
    let fm = FileManager.default
    var destination: URL { home.appendingPathComponent("Applications/CMPRS.app") }
    init(home: URL, app: URL, verifyApp: @escaping (URL) throws -> Void, checkpoint: @escaping (Int) throws -> Void = { _ in }) {
        self.home = home; self.app = app; self.verifyApp = verifyApp; self.checkpoint = checkpoint
    }
    func info(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return object
    }
    func bundleID(_ url: URL) -> String? { info(url)?["CFBundleIdentifier"] as? String }
    func isOurLegacyAction(_ url: URL) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true, let plist = info(url) else { return false }
        if let id = plist["CFBundleIdentifier"] as? String,
           ["com.glebkaravaev.cmprs.finder.h264", "com.glebkaravaev.cmprs.finder.hevc"].contains(id) { return true }
        guard let entries = plist["NSServices"] as? [[String: Any]],
              entries.contains(where: { ($0["NSMenuItem"] as? [String: String])?["default"] == "CMPRS Ironclad 100%" }),
              let data = try? Data(contentsOf: url.appendingPathComponent("Contents/document.wflow")),
              let workflow = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let actions = workflow["actions"] as? [[String: Any]] else { return false }
        return actions.contains { item in
            let parameters = (item["action"] as? [String: Any])?["ActionParameters"] as? [String: Any]
            let script = parameters?["COMMAND_STRING"] as? String ?? ""
            return script.contains("$HOME/Applications/CMPRS Ironclad.app") && script.contains("/usr/bin/open -n -a")
        }
    }
    func rejectLink(_ url: URL) throws {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw SetupFailure(text: "Installation path is a symbolic link: \(url.path)") }
    }
    // One app contains its own Finder service. Old workflows are retired only
    // when positively identified as ours, with rollback and a recoverable backup.
    func install() throws -> URL? {
        try verifyApp(app)
        guard bundleID(app) == "com.glebkaravaev.cmprs",
              let servicesInfo = info(app)?["NSServices"] as? [[String: Any]], servicesInfo.count == 1,
              servicesInfo.first?["NSMessage"] as? String == "compressSelection" else { throw SetupFailure(text: "The app does not contain the expected Finder service.") }
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        let services = home.appendingPathComponent("Library/Services", isDirectory: true)
        for parent in [applications, services] { try rejectLink(parent); try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
        try rejectLink(destination)
        if fm.fileExists(atPath: destination.path), bundleID(destination) != "com.glebkaravaev.cmprs" { throw SetupFailure(text: "Another app occupies the installation path; it was preserved.") }
        let token = UUID().uuidString
        let staging = applications.appendingPathComponent(".CMPRS-install-" + token)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent("CMPRS.app")
        try fm.copyItem(at: app, to: staged); try verifyApp(staged)
        let backupRoot = home.appendingPathComponent("Library/Application Support/CMPRS/Install Backups")
        try rejectLink(home.appendingPathComponent("Library/Application Support/CMPRS")); try rejectLink(backupRoot)
        let backup = backupRoot.appendingPathComponent(token)
        let previous = backup.appendingPathComponent("CMPRS.app.previous")
        var movedApp = false, installed = false
        var retired: [(URL, URL)] = []
        func prepareBackup() throws { try fm.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        do {
            if fm.fileExists(atPath: destination.path) { try prepareBackup(); try fm.moveItem(at: destination, to: previous); movedApp = true }
            try fm.moveItem(at: staged, to: destination); installed = true; try checkpoint(1)
            try verifyApp(destination)
            for name in ["CMPRS — H.264.workflow", "CMPRS — HEVC.workflow", "CMPRS Ironclad 100%.workflow"] {
                let legacy = services.appendingPathComponent(name)
                if isOurLegacyAction(legacy) {
                    try prepareBackup(); let saved = backup.appendingPathComponent(name + ".previous")
                    try fm.moveItem(at: legacy, to: saved); retired.append((legacy, saved)); try checkpoint(retired.count + 1)
                }
            }
        } catch {
            let first = error
            do {
                for pair in retired.reversed() { try fm.moveItem(at: pair.1, to: pair.0) }
                if installed { try fm.removeItem(at: destination) }
                if movedApp { try fm.moveItem(at: previous, to: destination) }
            } catch { throw SetupFailure(text: "Installation stopped. Recovery files: \(backup.path). \(first.localizedDescription) / \(error.localizedDescription)") }
            if fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: backup) }
            throw first
        }
        return movedApp || !retired.isEmpty ? backup : nil
    }
}
