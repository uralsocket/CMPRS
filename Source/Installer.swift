import AppKit
import Foundation
import Darwin

// SPDX-License-Identifier: AGPL-3.0-or-later
struct InstallFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

let russian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
func tr(_ ru: String, _ en: String) -> String { russian ? ru : en }

struct Installation {
    static let appName = "CMPRS Ironclad.app"
    static let actionName = "CMPRS Ironclad 100%.workflow"
    let home: URL
    let payload: URL
    let register: Bool
    let sourceApp: URL?
    init(home: URL, payload: URL, register: Bool, sourceApp: URL? = nil) {
        self.home = home; self.payload = payload; self.register = register; self.sourceApp = sourceApp
    }
    let fm = FileManager.default
    var appURL: URL { home.appendingPathComponent("Applications/\(Self.appName)") }
    var workflowURL: URL { home.appendingPathComponent("Library/Services/\(Self.actionName)") }
    var legacyURL: URL { home.appendingPathComponent("Library/Application Support/CMPRS Ironclad/\(Self.appName)") }

    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw InstallFailure(message: "\(URL(fileURLWithPath: executable).lastPathComponent): \(text.suffix(1800))")
        }
        return text
    }

    func verify(_ app: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", "-R", "=anchor apple generic and certificate leaf[subject.OU] = \"XPPNSDA36S\" and identifier \"local.gleb.cmprs-ironclad\"", app.path])
    }

    func install() throws -> String? {
        let sourceApp = self.sourceApp ?? payload.appendingPathComponent(Self.appName)
        let sourceAction = payload.appendingPathComponent(Self.actionName)
        guard fm.fileExists(atPath: sourceAction.appendingPathComponent("Contents/document.wflow").path) else {
            throw InstallFailure(message: tr("Установочный комплект повреждён. Скачайте его заново.", "The installer is incomplete. Download it again."))
        }
        try verify(sourceApp)
        if register && !NSRunningApplication.runningApplications(withBundleIdentifier: "local.gleb.cmprs-ironclad").isEmpty {
            throw InstallFailure(message: tr("Сначала закройте CMPRS Ironclad, затем нажмите «Установить» ещё раз. Дождитесь завершения текущего сжатия.", "Quit CMPRS Ironclad, then click Install again. Let any compression finish first."))
        }
        for app in [appURL, legacyURL] where fm.fileExists(atPath: app.path) {
            guard Bundle(url: app)?.bundleIdentifier == "local.gleb.cmprs-ironclad" else {
                throw InstallFailure(message: tr("В месте установки находится другое приложение: ", "Another app occupies the installation path: ") + app.path)
            }
        }
        let applications = appURL.deletingLastPathComponent()
        let services = workflowURL.deletingLastPathComponent()
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        try fm.createDirectory(at: services, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let appStage = applications.appendingPathComponent(".CMPRS-install-\(token)")
        let actionStage = services.appendingPathComponent(".CMPRS-install-\(token)")
        try fm.createDirectory(at: appStage, withIntermediateDirectories: false)
        do { try fm.createDirectory(at: actionStage, withIntermediateDirectories: false) }
        catch { try? fm.removeItem(at: appStage); throw error }
        var keepRecovery = false
        defer {
            if !keepRecovery { try? fm.removeItem(at: appStage); try? fm.removeItem(at: actionStage) }
        }
        let stagedApp = appStage.appendingPathComponent(Self.appName)
        let stagedAction = actionStage.appendingPathComponent(Self.actionName)
        try fm.copyItem(at: sourceApp, to: stagedApp)
        try fm.copyItem(at: sourceAction, to: stagedAction)
        try verify(stagedApp)
        let oldApp = appStage.appendingPathComponent("Previous.app")
        let oldAction = actionStage.appendingPathComponent("Previous.workflow")
        let oldLegacy = appStage.appendingPathComponent("Legacy.app")
        var movedApp = false, movedAction = false, movedLegacy = false
        var installedApp = false, installedAction = false
        do {
            if fm.fileExists(atPath: appURL.path) { try fm.moveItem(at: appURL, to: oldApp); movedApp = true }
            if fm.fileExists(atPath: workflowURL.path) { try fm.moveItem(at: workflowURL, to: oldAction); movedAction = true }
            if fm.fileExists(atPath: legacyURL.path) { try fm.moveItem(at: legacyURL, to: oldLegacy); movedLegacy = true }
            try fm.moveItem(at: stagedApp, to: appURL); installedApp = true
            try fm.moveItem(at: stagedAction, to: workflowURL); installedAction = true
            try verify(appURL)
        } catch {
            let originalError = error
            do {
                if installedAction { try fm.removeItem(at: workflowURL) }
                if installedApp { try fm.removeItem(at: appURL) }
                if movedAction { try fm.moveItem(at: oldAction, to: workflowURL) }
                if movedApp { try fm.moveItem(at: oldApp, to: appURL) }
                if movedLegacy { try fm.moveItem(at: oldLegacy, to: legacyURL) }
            } catch {
                keepRecovery = true
                throw InstallFailure(message: tr("Не удалось восстановить предыдущую установку. Резервная копия сохранена в:\n", "Could not restore the previous installation. Recovery files are preserved in:\n") + appStage.path + "\n" + actionStage.path + "\n" + originalError.localizedDescription + "\n" + error.localizedDescription)
            }
            throw originalError
        }
        if register {
            do {
                try run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", appURL.path])
                try run("/System/Library/CoreServices/pbs", ["-flush"])
                try run("/System/Library/CoreServices/pbs", ["-update"])
                try run(appURL.appendingPathComponent("Contents/MacOS/CMPRS").path, ["--register-service"])
            } catch {
                return tr("Файлы установлены. Если действие не появилось в Finder, включите «CMPRS Ironclad 100%» в настройках клавиатуры → Сочетания клавиш → Службы.", "The files are installed. If the action is missing in Finder, enable CMPRS Ironclad 100% in Keyboard Settings → Keyboard Shortcuts → Services.")
            }
        }
        return nil
    }
}

final class InstallerDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var heading: NSTextField!
    var body: NSTextField!
    var button: NSButton!
    var spinner: NSProgressIndicator!
    var working = false
    var completed = false
    let installation = Installation(home: FileManager.default.homeDirectoryForCurrentUser, payload: Bundle.main.resourceURL!.appendingPathComponent("Payload"), register: true, sourceApp: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CMPRS Ironclad.app"))

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 422), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = tr("Установить CMPRS", "Install CMPRS")
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        let root = window.contentView!
        let icon = NSImageView()
        icon.image = NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("CMPRS.icns"))
        icon.imageScaling = .scaleProportionallyUpOrDown
        heading = NSTextField(labelWithString: "CMPRS")
        heading.font = .systemFont(ofSize: 30, weight: .semibold)
        heading.alignment = .center
        let subtitle = NSTextField(labelWithString: tr("Сжатие видео прямо в Finder", "Video compression in Finder"))
        subtitle.font = .systemFont(ofSize: 16, weight: .medium)
        subtitle.alignment = .center
        body = NSTextField(wrappingLabelWithString: tr("Установит приложение и быстрое действие.\nВыбирайте несколько видео и сжимайте их\nодним нажатием — оригиналы сохранятся.", "Installs the app and a Finder Quick Action.\nSelect multiple videos and compress them\nin one go. Your originals are preserved."))
        body.font = .systemFont(ofSize: 14)
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        button = NSButton(title: tr("Установить", "Install"), target: self, action: #selector(installOrClose))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [icon, heading!, subtitle, body!, button!, spinner!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: root.centerXAnchor), icon.topAnchor.constraint(equalTo: root.topAnchor, constant: 22), icon.widthAnchor.constraint(equalToConstant: 100), icon.heightAnchor.constraint(equalToConstant: 100),
            heading.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12), heading.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8), subtitle.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            body.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24), body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 34), body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -34),
            button.widthAnchor.constraint(equalToConstant: 180), button.centerXAnchor.constraint(equalTo: root.centerXAnchor), button.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -30),
            spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor), spinner.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12)
        ])
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func installOrClose() {
        if completed { NSApp.terminate(nil); return }
        guard !working else { return }
        working = true
        button.title = tr("Установка…", "Installing…")
        button.isEnabled = false
        window.standardWindowButton(.closeButton)?.isEnabled = false
        spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result: Result<String?, Error>
            do { result = .success(try installation.install()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async { [self] in
                working = false
                spinner.stopAnimation(nil)
                button.isEnabled = true
                window.standardWindowButton(.closeButton)?.isEnabled = true
                switch result {
                case .success(let warning):
                    completed = true
                    heading.stringValue = tr("Установлено", "Installed")
                    body.stringValue = warning ?? tr("Выделите видео в Finder → Быстрые действия\n→ CMPRS Ironclad 100%.\nГотовые MOV появятся рядом с оригиналами.", "Select videos in Finder → Quick Actions\n→ CMPRS Ironclad 100%.\nThe MOV files appear beside your originals.")
                    button.title = tr("Готово", "Done")
                case .failure(let error):
                    button.title = tr("Установить", "Install")
                    let alert = NSAlert()
                    alert.messageText = tr("Не удалось установить CMPRS", "CMPRS could not be installed")
                    alert.informativeText = error.localizedDescription
                    alert.addButton(withTitle: "OK")
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if working { return false }
        NSApp.terminate(nil)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { working ? .terminateCancel : .terminateNow }
}

#if INSTALLER_TESTING
let args = Array(CommandLine.arguments.dropFirst())
if args.count == 4 && args[0] == "--test-install" && args[2] == "--payload" {
    do {
        let installation = Installation(home: URL(fileURLWithPath: args[1]), payload: URL(fileURLWithPath: args[3]), register: false)
        let warning = try installation.install()
        print(warning ?? "installed")
        exit(0)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
}
#endif
let app = NSApplication.shared
let delegate = InstallerDelegate()
app.delegate = delegate
app.run()
