import AppKit
import WebKit
import Foundation

private struct QueueFile {
    let id = UUID().uuidString
    let url: URL
    let scoped: Bool
    let bytes: Int64
    var status = "queued"
    var message: String?
    var output: URL?
    var outputBytes: Int64?
}

// Folder grants live only for this app session. No bookmarks or processing history.
private final class FolderPermissions {
    private var open: [URL] = []
    func access(_ folder: URL) -> Bool { open.contains { $0.standardizedFileURL == folder.standardizedFileURL } }
    func remember(_ url: URL, expected: URL) throws {
        guard url.standardizedFileURL == expected.standardizedFileURL else { throw NativeFailure("Select the source folder: \(expected.lastPathComponent).") }
        _ = url.startAccessingSecurityScopedResource(); open.append(url)
    }
    func release() { for url in open { url.stopAccessingSecurityScopedResource() }; open.removeAll() }
    func forget() { release() }
}

private final class DropWebView: WKWebView {
    var receive: (([URL]) -> Void)?
    var dragState: ((Bool) -> Void)?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hasFiles = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        dragState?(hasFiles); return hasFiles ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { dragState?(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragState?(false)
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }; receive?(urls); return true
    }
}

final class NativeApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, @unchecked Sendable {
    private var window: NSWindow!
    private var web: DropWebView!
    private var loaded = false
    private var webFailures = 0
    private var launched = false
    private var pendingOpen: [URL] = []
    private var files: [QueueFile] = []
    private var language = Bundle.main.preferredLocalizations.first == "ru" ? "ru" : "en"
    private let mode = CompressionMode.compatible
    private let container = ContainerFormat.mov
    private var allow8Bit = false
    private var working = false, preparing = false, finished = false, cancelling = false, quitting = false
    private var progress = 0.0, stage = "queued"
    private var message: String?
    private var runner: EngineRunner?
    private let permissions = FolderPermissions()
    private let resources = Bundle.main.resourceURL!.appendingPathComponent("UI")
    private func local(_ en: String, _ ru: String) -> String { language == "ru" ? ru : en }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        makeMenu(); makeWindow(); launched = true
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if !pendingOpen.isEmpty { let urls = pendingOpen; pendingOpen.removeAll(); handleOpen(urls) }
    }
    func application(_ sender: NSApplication, open urls: [URL]) { if launched { handleOpen(urls) } else { pendingOpen.append(contentsOf: urls) } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if working { quitting = true; cancel(); return .terminateLater }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { releaseFiles(); permissions.release() }
    private func handleOpen(_ urls: [URL]) {
        let requests = urls.filter { $0.pathExtension.lowercased() == FinderRequest.fileExtension }
        let videos = urls.filter { $0.pathExtension.lowercased() != FinderRequest.fileExtension }
        if !videos.isEmpty { receive(videos); start() }
        for url in requests {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { let request = try FinderRequest.read(url); FinderRequest.consumeTemporary(url); receiveFinder(request) }
            catch { message = error.localizedDescription; emit() }
        }
    }
    private func receiveFinder(_ request: FinderRequest) {
        guard !working && !preparing else { message = local("CMPRS is busy. Finish or cancel this batch, then run the Finder action again.", "CMPRS занят. Заверши или отмени очередь и запусти действие Finder снова."); emit(); return }
        preparing = true; message = nil; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); emit()
        var folders: [URL] = []
        for input in request.inputs { let folder = input.deletingLastPathComponent(); if !folders.contains(folder) { folders.append(folder) } }
        authorize(folders, index: 0) { [weak self] in
            guard let self else { return }
            self.releaseFiles(); self.files.removeAll(); self.finished = false; self.progress = 0
            self.allow8Bit = false
            self.receive(request.inputs)
            guard !self.files.isEmpty else { self.message = self.local("The selected videos could not be accessed.", "Нет доступа к выбранным видео."); self.emit(); return }
            self.start()
        }
    }
    @objc func compressSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] { urls = paths.map { URL(fileURLWithPath: $0) } }
        guard !urls.isEmpty else { error.pointee = local("Select video files in Finder.", "Выбери видеофайлы в Finder.") as NSString; return }
        guard !working && !preparing else { error.pointee = local("CMPRS is processing a batch.", "CMPRS уже обрабатывает очередь.") as NSString; return }
        DispatchQueue.main.async { [self] in receive(urls); start() }
    }
    private func makeMenu() {
        let main = NSMenu(); let item = NSMenuItem(); let app = NSMenu(title: "CMPRS")
        app.addItem(withTitle: local("About CMPRS", "О CMPRS"), action: #selector(about), keyEquivalent: "")
        app.addItem(.separator()); let service = NSMenuItem(title: local("Services", "Службы"), action: nil, keyEquivalent: ""); service.submenu = NSMenu(title: local("Services", "Службы")); NSApp.servicesMenu = service.submenu; app.addItem(service)
        app.addItem(.separator()); app.addItem(withTitle: local("Hide CMPRS", "Скрыть CMPRS"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); app.addItem(withTitle: local("Quit CMPRS", "Завершить CMPRS"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = app; main.addItem(item)
        let file = NSMenuItem(); let menu = NSMenu(title: local("File", "Файл")); menu.addItem(withTitle: local("Add videos…", "Выбрать видео…"), action: #selector(choose), keyEquivalent: "o"); menu.addItem(withTitle: local("Close Window", "Закрыть окно"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"); file.submenu = menu; main.addItem(file)
        let editItem = NSMenuItem(); let edit = NSMenu(title: local("Edit", "Правка"))
        for (title, selector, key) in [(local("Copy", "Копировать"), #selector(NSText.copy(_:)), "c"), (local("Select All", "Выбрать всё"), #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: title, action: selector, keyEquivalent: key) }
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 560), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "CMPRS"; window.minSize = NSSize(width: 360, height: 480); window.delegate = self; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(srgbRed: 221/255, green: 214/255, blue: 199/255, alpha: 1); window.appearance = NSAppearance(named: .aqua)
        let config = WKWebViewConfiguration(); config.userContentController.add(self, name: "cmprs")
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        web = DropWebView(frame: .zero, configuration: config); web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.registerForDraggedTypes([.fileURL]); web.receive = { [weak self] in self?.receive($0); self?.start() }
        web.dragState = { [weak self] value in self?.web.callAsyncJavaScript("window.cmprsDrag?.(value)", arguments: ["value": value], in: nil, in: .page, completionHandler: nil) }
        window.contentView = web
        web.loadFileURL(resources.appendingPathComponent("index.html"), allowingReadAccessTo: resources)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL, url.standardizedFileURL.path == resources.appendingPathComponent("index.html").standardizedFileURL.path else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { message = error.localizedDescription; emit() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { message = error.localizedDescription; emit() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webFailures += 1
        if webFailures == 1 { loaded = false; webView.reload() }
        else { let alert = NSAlert(); alert.messageText = local("CMPRS interface could not start", "Не удалось открыть интерфейс CMPRS"); alert.informativeText = local("Apple’s WebKit process stopped. Close and reopen CMPRS.", "Процесс WebKit завершился. Закрой и снова открой CMPRS."); alert.beginSheetModal(for: window, completionHandler: nil) }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive scriptMessage: WKScriptMessage) {
        guard scriptMessage.frameInfo.isMainFrame, scriptMessage.frameInfo.request.url?.standardizedFileURL == resources.appendingPathComponent("index.html").standardizedFileURL,
              let body = scriptMessage.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready": loaded = true
        case "choose": choose()
        case "start": start()
        case "cancel": cancel()
        case "done": if !working && !preparing { NSApp.terminate(nil) }
        default: break
        }
        emit()
    }
    private func emit() {
        guard loaded else { return }
        let queue: [[String: Any]] = files.map { f in
            var d: [String: Any] = ["id": f.id, "name": f.url.lastPathComponent, "bytes": f.bytes, "status": f.status]
            if let value = f.message { d["message"] = value }; if let value = f.outputBytes { d["outputBytes"] = value }; return d
        }
        var state: [String: Any] = ["language": language, "mode": mode.rawValue, "container": container.rawValue, "allow8Bit": allow8Bit, "working": working, "preparing": preparing, "cancelling": cancelling, "finished": finished, "progress": min(1, max(0, progress)), "stage": stage, "files": queue, "savedBytes": files.filter { $0.status == "ok" }.reduce(Int64(0)) { $0 + max(0, $1.bytes - ($1.outputBytes ?? $1.bytes)) }]
        if let message { state["message"] = message }
        web.callAsyncJavaScript("window.cmprsReceive?.(state)", arguments: ["state": state], in: nil, in: .page, completionHandler: nil)
    }
    private func releaseFiles() { for f in files where f.scoped { f.url.stopAccessingSecurityScopedResource() } }
    private func receive(_ urls: [URL]) {
        guard !working && !preparing else { message = local("Finish or cancel this batch before adding files.", "Заверши или отмени текущую очередь, чтобы добавить файлы."); emit(); return }
        if finished { releaseFiles(); files.removeAll(); finished = false; progress = 0 }
        for url in urls where url.isFileURL {
            let normalized = url.standardizedFileURL
            guard !files.contains(where: { $0.url == normalized }) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            guard (try? normalized.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { if scoped { url.stopAccessingSecurityScopedResource() }; continue }
            files.append(QueueFile(url: normalized, scoped: scoped, bytes: fileBytes(normalized)))
        }
        message = nil; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); emit()
    }
    @objc private func choose() {
        guard !working && !preparing else { return }
        let panel = NSOpenPanel(); panel.title = local("Choose videos", "Выбрать видео"); panel.prompt = local("Add", "Добавить"); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in if response == .OK { self?.receive(panel.urls); self?.start() } }
    }
    private func start() {
        guard !working && !preparing && !finished && !files.isEmpty else { return }
        preparing = true; message = nil; emit()
        var folders: [URL] = []; for file in files { let folder = file.url.deletingLastPathComponent(); if !folders.contains(folder) { folders.append(folder) } }
        authorize(folders, index: 0)
    }
    private func authorize(_ folders: [URL], index: Int, completion: (() -> Void)? = nil) {
        guard index < folders.count else { preparing = false; if let completion { completion() } else { encodeBatch() }; return }
        let folder = folders[index]
        if permissions.access(folder) { authorize(folders, index: index + 1, completion: completion); return }
        let panel = NSOpenPanel(); panel.title = local("Allow saving beside the originals", "Разрешить сохранение рядом с исходниками"); panel.prompt = local("Allow folder", "Разрешить папку")
        panel.message = local("Select this source folder to save CMPRS- files beside your videos. This permission lasts only until CMPRS closes.\n", "Выбери папку исходников, чтобы сохранить CMPRS- рядом с видео. Разрешение действует только до закрытия CMPRS.\n") + folder.path
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = false; panel.allowsMultipleSelection = false; panel.directoryURL = folder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let selected = panel.url else { self.preparing = false; self.finished = true; self.stage = "cancelled"; self.permissions.release(); self.emit(); return }
            do { try self.permissions.remember(selected, expected: folder); self.authorize(folders, index: index + 1, completion: completion) }
            catch { self.preparing = false; self.permissions.release(); self.message = error.localizedDescription; self.emit() }
        }
    }
    private func encodeBatch() {
        let selectedMode = mode, selectedContainer = container, urls = files.map(\.url)
        var consent = allow8Bit
        let worker = EngineRunner(binary: Bundle.main.resourceURL!.appendingPathComponent("bin"))
        runner = worker; working = true; finished = false; cancelling = false; progress = 0; stage = "inspecting"
        for index in files.indices { files[index].status = "queued"; files[index].message = nil; files[index].output = nil; files[index].outputBytes = nil }
        emit()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "CMPRS local video compression")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            for (index, url) in urls.enumerated() {
                if worker.isCancelled { break }
                DispatchQueue.main.async { [self] in files[index].status = "inspecting"; stage = "inspecting"; emit() }
                do {
                    var result = try worker.run(url, mode: selectedMode, container: selectedContainer, allow8Bit: consent) { [self] event in
                        DispatchQueue.main.async { [self] in
                            if let value = event.stage, ["inspecting", "encoding", "verifying"].contains(value) { files[index].status = value; stage = value }
                            if let value = event.progress, event.type != "result" { progress = (Double(index) + min(0.999, max(0, value))) / Double(urls.count) }
                            emit()
                        }
                    }
                    if result.status == "needs-consent", !worker.isCancelled {
                        var approved = false
                        DispatchQueue.main.sync { [self] in
                            let alert = NSAlert(); alert.messageText = self.local("Convert 10/12-bit video to compatible H.264?", "Перевести 10/12-битное видео в совместимый H.264?")
                            alert.informativeText = self.local("8-bit 4:2:0 plays broadly on Mac, iPhone and Windows. Resolution and frame timing stay unchanged. Applies to this batch only.", "8 бит 4:2:0 подходит для Mac, iPhone и Windows. Разрешение и тайминг кадров сохранятся. Только для этой очереди.")
                            alert.addButton(withTitle: self.local("Convert to 8-bit", "Перевести в 8 бит")); alert.addButton(withTitle: self.local("Skip this file", "Пропустить файл"))
                            approved = alert.runModal() == .alertFirstButtonReturn
                        }
                        if approved && !worker.isCancelled {
                            consent = true
                            result = try worker.run(url, mode: selectedMode, container: selectedContainer, allow8Bit: true) { [self] event in
                                DispatchQueue.main.async { [self] in
                                    if let value = event.stage { files[index].status = value; stage = value }
                                    if let value = event.progress { progress = (Double(index) + min(0.999, max(0, value))) / Double(urls.count) }; emit()
                                }
                            }
                        } else { result.status = worker.isCancelled ? "cancelled" : "skipped"; result.message = self.local("8-bit conversion was not allowed. Original unchanged.", "Переход в 8 бит не разрешён. Оригинал сохранён.") }
                    }
                    let completedResult = result
                    DispatchQueue.main.async { [self] in
                        files[index].status = completedResult.status ?? "error"; files[index].message = completedResult.message
                        if let output = completedResult.output { files[index].output = URL(fileURLWithPath: output) }; files[index].outputBytes = completedResult.outputBytes
                        if completedResult.status != "cancelled" { progress = Double(index + 1) / Double(urls.count) }; emit()
                    }
                } catch {
                    let detail = error.localizedDescription
                    DispatchQueue.main.async { [self] in
                        files[index].status = worker.isCancelled ? "cancelled" : "error"; files[index].message = detail
                        emit()
                    }
                }
            }
            DispatchQueue.main.async { [self] in
                for index in files.indices where ["queued", "inspecting", "encoding", "verifying"].contains(files[index].status) { files[index].status = worker.isCancelled ? "cancelled" : "error" }
                working = false; finished = true; cancelling = false; stage = worker.isCancelled ? "cancelled" : "done"
                if !worker.isCancelled { progress = 1 }; permissions.release(); runner = nil; emit()
                if quitting { NSApp.reply(toApplicationShouldTerminate: true) }
            }
        }
    }
    private func cancel() {
        if preparing {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            preparing = false; finished = true; stage = "cancelled"; permissions.release(); emit(); return
        }
        guard working else { return }; cancelling = true; runner?.cancel(); emit()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }

    @objc private func about() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "CMPRS", .applicationVersion: "2.0.0", .credits: NSAttributedString(string: "Ironclad / x264 CRF 24 slow · React interface\nAll processing stays on your Mac.\n© 2026 Gleb Karavaev")]) }
    @objc private func forget() { guard !working && !preparing else { return }; permissions.forget(); message = local("Saved folder permissions cleared.", "Сохранённые разрешения на папки очищены."); emit() }
}

@main enum AppMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = NativeApp()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
