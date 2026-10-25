import AppKit
import Foundation
import CoreFoundation

private func local(_ en: String, _ ru: String) -> String { Bundle.main.preferredLocalizations.first == "ru" ? ru : en }

@main final class SetupApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var body: NSTextField!
    var button: NSButton!
    var spinner: NSProgressIndicator!
    var working = false, completed = false
    var installed: URL?
    let resources = Bundle.main.resourceURL!
    static func run(_ executable: String, _ arguments: [String]) throws {
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardInput = FileHandle.nullDevice; task.standardOutput = pipe; task.standardError = pipe
        try task.run(); let output = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SetupFailure(text: String(decoding: output.suffix(3000), as: UTF8.self)) }
    }
    static func verify(_ url: URL) throws {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--all-architectures", "-R", "=anchor apple generic and certificate leaf[subject.OU] = \"XPPNSDA36S\" and identifier \"com.glebkaravaev.cmprs\"", url.path])
    }
    static func enableFinderService() throws {
        let domain = "pbs" as CFString, key = "NSServicesStatus" as CFString
        let name = "com.glebkaravaev.cmprs - CMPRS — Compress video - compressSelection"
        var all = CFPreferencesCopyAppValue(key, domain) as? [String: Any] ?? [:]
        var item = all[name] as? [String: Any] ?? [:]
        var modes = item["presentation_modes"] as? [String: Any] ?? [:]
        modes["ContextMenu"] = true; modes["ServicesMenu"] = true
        item["presentation_modes"] = modes; item["enabled_context_menu"] = true; item["enabled_services_menu"] = true
        all[name] = item; CFPreferencesSetAppValue(key, all as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw SetupFailure(text: local("The Finder action could not be enabled.", "Не удалось включить действие Finder.")) }
    }
    static func main() { let app = NSApplication.shared; let delegate = SetupApp(); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() } }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let bar = NSMenu(); let item = NSMenuItem(); let menu = NSMenu(title: local("Install CMPRS", "Установить CMPRS"))
        menu.addItem(withTitle: "Quit Install CMPRS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = menu; bar.addItem(item); NSApp.mainMenu = bar
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = local("Install CMPRS", "Установить CMPRS"); window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false; window.delegate = self
        window.backgroundColor = NSColor(srgbRed: 221/255, green: 214/255, blue: 199/255, alpha: 1); window.appearance = NSAppearance(named: .aqua)
        let title = NSTextField(labelWithString: "CMPRS / SETUP"); title.font = .monospacedSystemFont(ofSize: 25, weight: .bold)
        body = NSTextField(wrappingLabelWithString: local("Install CMPRS and its Finder action.\n\nSelect videos → CMPRS — Compress video.\nIronclad compression. Always MOV.\n\nFor your account. No administrator password.", "Установить CMPRS и действие Finder.\n\nВыбери видео → CMPRS — Сжать видео.\nСжатие Ironclad. Всегда MOV.\n\nДля твоего аккаунта. Без пароля администратора."))
        body.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        button = NSButton(title: local("Install CMPRS", "Установить CMPRS"), target: self, action: #selector(install)); button.bezelStyle = .rounded; button.controlSize = .large; button.keyEquivalent = "\r"
        spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.isDisplayedWhenStopped = false
        for view in [title, body!, button!, spinner!] { view.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(view) }
        let root = window.contentView!
        NSLayoutConstraint.activate([title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),title.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),body.leadingAnchor.constraint(equalTo: title.leadingAnchor),body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),button.centerXAnchor.constraint(equalTo: root.centerXAnchor),button.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -25),spinner.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12),spinner.centerYAnchor.constraint(equalTo: button.centerYAnchor)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func install() {
        if completed { if let installed { NSWorkspace.shared.openApplication(at: installed, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil) }; NSApp.terminate(nil); return }
        guard !working else { return }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.glebkaravaev.cmprs").isEmpty else { show(local("Quit CMPRS first, then click Install again. Let any compression finish before quitting.", "Сначала закрой CMPRS, затем повтори установку. Дождись окончания текущего сжатия.")); return }
        working = true; button.isEnabled = false; button.title = local("Installing…", "Устанавливаем…"); spinner.startAnimation(nil)
        let installation = InstallCore(home: FileManager.default.homeDirectoryForCurrentUser, app: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CMPRS.app"), verifyApp: Self.verify)
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                _ = try installation.install()
                var registered = true
                do {
                    try Self.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", installation.destination.path])
                    try Self.run("/System/Library/CoreServices/pbs", ["-flush"])
                    try Self.enableFinderService()
                    try Self.run("/System/Library/CoreServices/pbs", ["-update"])
                } catch { registered = false }
                DispatchQueue.main.async { [self] in
                    NSUpdateDynamicServices(); working = false; completed = true; installed = installation.destination; spinner.stopAnimation(nil); button.isEnabled = true; button.title = local("Open CMPRS", "Открыть CMPRS")
                    body.stringValue = registered ? local("CMPRS INSTALLED\n\nSelect videos in Finder → CMPRS — Compress video.\nThe batch starts automatically.\n\nIf macOS groups services, check Services.\nAllow the source folder when macOS asks.", "CMPRS УСТАНОВЛЕН\n\nВыбери видео в Finder → CMPRS — Сжать видео.\nОчередь запустится автоматически.\n\nЕсли macOS сгруппировала пункты, открой Службы.\nРазреши папку исходников при запросе macOS.") : local("CMPRS is installed.\nmacOS could not refresh its Services list.\n\nLog out and back in, then check Finder\n→ Services → CMPRS — Compress video.", "CMPRS установлен.\nНе удалось обновить список служб macOS.\n\nВыйди из аккаунта и войди снова, затем проверь\nFinder → Службы → CMPRS — Сжать видео.")
                }
            } catch { DispatchQueue.main.async { [self] in working = false; spinner.stopAnimation(nil); button.isEnabled = true; button.title = local("Install CMPRS", "Установить CMPRS"); show(error.localizedDescription) } }
        }
    }
    func show(_ text: String) { let alert = NSAlert(); alert.messageText = "CMPRS Setup"; alert.informativeText = text; alert.beginSheetModal(for: window, completionHandler: nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if working { return false }; NSApp.terminate(nil); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { working ? .terminateCancel : .terminateNow }
}
