import AppKit
import Foundation
import Darwin

// Ironclad quality=100: compressO ffmpeg.rs, CRF = 24, preset = slow.
// Deliberate adaptation: preserve source pixel format instead of forcing yuv420p.
struct JobResult: Codable {
    let input: String
    let status: String
    let output: String?
    let message: String
    let originalBytes: Int64
    let outputBytes: Int64
}

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// The journal exists during processing, including when an encoder stops responding.
final class DiagnosticJournal: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private let handle: FileHandle?

    init() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CMPRS")
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("CMPRS")
        let root = (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil ? folder : fallback
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        url = root.appendingPathComponent("Session-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        write("CMPRS \(version) · \(ProcessInfo.processInfo.operatingSystemVersionString) · arm64 · CPU \(ProcessInfo.processInfo.activeProcessorCount) · RAM \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GiB")
    }

    func write(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        try? handle?.write(contentsOf: Data("[\(ISO8601DateFormatter().string(from: Date()))] \(text)\n".utf8))
    }

    func contents() -> String {
        lock.lock(); defer { lock.unlock() }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "Не удалось прочитать журнал: \(url.path)"
    }

    deinit { try? handle?.close() }
}

final class Compressor: @unchecked Sendable {
    let bin: URL
    let journal = DiagnosticJournal()
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false
    var event: (String, Double) -> Void = { _, _ in }
    // An idle limit, not a limit on the duration of an encoding job.
    let probeIdleLimit: TimeInterval
    let encodeIdleLimit: TimeInterval

    init(bin: URL? = nil, probeIdleLimit: TimeInterval = 60, encodeIdleLimit: TimeInterval = 300) {
        self.bin = bin ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin")
        self.probeIdleLimit = probeIdleLimit
        self.encodeIdleLimit = encodeIdleLimit
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = child
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }

    private func run(_ tool: String, _ args: [String], duration: Double = 0, frameCount: Double = 0) throws -> Data {
        if isCancelled { throw Failure(message: "Отменено") }
        let p = Process()
        p.executableURL = bin.appendingPathComponent(tool)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        // Regular files never wait for pipe EOF. A stopped child or an inherited
        // stdout descriptor must not block cancellation or failure reporting.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CMPRS-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stdoutURL = folder.appendingPathComponent("stdout")
        let stderrURL = folder.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: stdoutURL)
        let errors = try FileHandle(forWritingTo: stderrURL)
        let reader = try FileHandle(forReadingFrom: stdoutURL)
        let errorReader = try FileHandle(forReadingFrom: stderrURL)
        p.standardOutput = output
        p.standardError = errors
        defer {
            try? output.close(); try? errors.close(); try? reader.close(); try? errorReader.close()
            try? FileManager.default.removeItem(at: folder)
            lock.lock(); child = nil; lock.unlock()
        }
        journal.write("Запуск \(tool): \(args)")
        lock.lock()
        if cancelled { lock.unlock(); throw Failure(message: "Отменено") }
        do { try p.run(); child = p; lock.unlock() }
        catch { lock.unlock(); journal.write("Ошибка запуска: \(error)"); throw error }
        try? output.close(); try? errors.close()
        journal.write("\(tool) PID \(p.processIdentifier)")
        let started = ProcessInfo.processInfo.systemUptime
        var changedAt = started, lastUI = started - 1, lastLog = started - 10
        var stopAt: TimeInterval?, timeoutMessage: String?
        var pending = "", fields: [String: String] = [:]
        var lastFrame: Double = 0, lastTime: Double = 0, lastSize: Int64 = 0
        var fraction: Double = -1
        let destination = tool == "ffmpeg" ? args.last.map { URL(fileURLWithPath: $0) } : nil
        let stage = tool == "ffprobe" ? "Чтение параметров…" : "Подготовка кадров…"
        func consume(_ data: Data) {
            guard tool == "ffmpeg", !data.isEmpty else { return }
            pending += String(decoding: data, as: UTF8.self)
            while let end = pending.firstIndex(of: "\n") {
                let line = String(pending[..<end]); pending.removeSubrange(...end)
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if let data = try? reader.readToEnd() { consume(data) }
            let frame = Double(fields["frame"] ?? "") ?? 0
            let time = (Double(fields["out_time_us"] ?? "") ?? 0) / 1_000_000
            let size = max(Int64(fields["total_size"] ?? "") ?? 0, destination.map { bytes($0) } ?? 0)
            if frame > lastFrame || time > lastTime || size > lastSize {
                changedAt = now; lastFrame = max(lastFrame, frame); lastTime = max(lastTime, time); lastSize = max(lastSize, size)
            }
            if time > 0 && duration > 0 { fraction = min(0.97, time / duration) }
            else if frame > 0 && frameCount > 0 { fraction = min(0.97, frame / frameCount) }
            if now - lastUI >= 1 {
                let elapsed = Int(now - started)
                let clock = "\(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
                let state = tool == "ffmpeg" && fraction >= 0 ? "Сжатие… \(Int(fraction * 100))% · \(Int(frame)) кадров" : stage
                event("\(state) · \(clock)", fraction)
                lastUI = now
            }
            if now - lastLog >= 10 {
                if let data = try? errorReader.readToEnd(), !data.isEmpty { journal.write(String(decoding: data.suffix(24_000), as: UTF8.self)) }
                journal.write("\(tool): \(Int(now - started)) с · кадры \(Int(frame)) · время видео \(time) · байт \(size)")
                lastLog = now
            }
            guard p.isRunning else { break }
            if stopAt == nil {
                if isCancelled {
                    stopAt = now; p.terminate()
                } else if now - changedAt > (tool == "ffprobe" ? probeIdleLimit : encodeIdleLimit) {
                    timeoutMessage = tool == "ffprobe" ? "Не удалось прочитать файл: ffprobe перестал отвечать." : "Кодировщик не продвинулся за 5 минут. Обработка остановлена; оригинал сохранён. Скопируйте диагностику для проверки причины."
                    journal.write(timeoutMessage!)
                    stopAt = now; p.terminate()
                }
            } else if now - stopAt! >= 3 {
                // Only this still-running Process is signalled, never an arbitrary PID.
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        p.waitUntilExit()
        let diagnostic = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        journal.write("\(tool) завершён: \(p.terminationReason == .uncaughtSignal ? "сигнал" : "код") \(p.terminationStatus)\n\(diagnostic.suffix(24_000))")
        if isCancelled { throw Failure(message: "Отменено") }
        if let timeoutMessage { throw Failure(message: timeoutMessage) }
        if p.terminationStatus != 0 {
            let reason = p.terminationReason == .uncaughtSignal ? "сигнал \(p.terminationStatus)" : "код \(p.terminationStatus)"
            throw Failure(message: "\(tool) (\(reason)): \(diagnostic.isEmpty ? "Кодировщик завершился без сообщения. Скопируйте диагностику." : String(diagnostic.suffix(5000)))")
        }
        return tool == "ffprobe" ? try Data(contentsOf: stdoutURL) : Data()
    }

    private func probe(_ url: URL) throws -> [String: Any] {
        let data = try run("ffprobe", ["-v", "error", "-show_streams", "-show_format", "-show_chapters", "-of", "json", url.path])
        guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Не удалось прочитать параметры файла")
        }
        return info
    }

    private func streams(_ info: [String: Any], _ type: String) -> [[String: Any]] {
        (info["streams"] as? [[String: Any]] ?? []).filter { $0["codec_type"] as? String == type }
    }

    private func text(_ stream: [String: Any], _ key: String) -> String {
        guard let v = stream[key] else { return "" }
        return String(describing: v)
    }

    private func bytes(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    private func isCover(_ s: [String: Any]) -> Bool {
        (s["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
    }

    private func pixelFormat(_ s: [String: Any]) throws -> (String, String) {
        let pixel = text(s, "pix_fmt")
        let side = s["side_data_list"] as? [[String: Any]] ?? []
        let transfer = text(s, "color_transfer")
        if transfer == "smpte2084" || transfer == "arib-std-b67" || side.contains(where: {
            let type = String(describing: $0["side_data_type"] ?? "").lowercased()
            return type.contains("dovi") || type.contains("mastering") || type.contains("content light") || type.contains("hdr")
        }) {
            throw Failure(message: "HDR / Dolby Vision: Ironclad H.264 не сохраняет все HDR-метаданные. Файл пропущен без изменения.")
        }
        if pixel.hasPrefix("yuva") || pixel.hasPrefix("gbrap") || ["rgba", "bgra", "argb", "abgr", "ya8", "ya16le"].contains(pixel) ||
            (s["tags"] as? [String: Any])?["alpha_mode"] != nil {
            throw Failure(message: "Видео с прозрачностью: Ironclad H.264 не поддерживает alpha. Файл пропущен без изменения.")
        }
        let supported = ["yuv420p", "yuvj420p", "yuv422p", "yuvj422p", "yuv444p", "yuvj444p", "yuv420p10le", "yuv422p10le", "yuv444p10le", "gray", "gray10le"]
        if supported.contains(pixel) { return (pixel, "libx264") }
        if pixel == "nv12" { return ("yuv420p", "libx264") }
        if pixel == "nv16" { return ("yuv422p", "libx264") }
        if pixel == "p010le" { return ("yuv420p10le", "libx264") }
        if ["rgb24", "bgr24", "gbrp"].contains(pixel) { return ("rgb24", "libx264rgb") }
        throw Failure(message: "Пиксельный формат \(pixel) нельзя сохранить в Ironclad H.264. Файл пропущен без изменения.")
    }

    private func validate(_ source: [String: Any], _ dest: [String: Any]) throws {
        let sv = streams(source, "video").filter { !isCover($0) }
        let dv = streams(dest, "video").filter { !isCover($0) }
        guard sv.count == dv.count else { throw Failure(message: "Проверка: изменилось количество видеодорожек") }
        for (a, b) in zip(sv, dv) {
            for key in ["width", "height", "sample_aspect_ratio", "color_space", "color_transfer", "color_primaries", "color_range"] {
                let original = text(a, key)
                if !original.isEmpty && original != "unknown" && original != "N/A" && original != text(b, key) {
                    throw Failure(message: "Проверка: параметр \(key) изменился с \(original) на \(text(b, key))")
                }
            }
            func fieldDisplayOrder(_ value: String) -> String {
                if ["tt", "bt"].contains(value) { return "top" }
                if ["bb", "tb"].contains(value) { return "bottom" }
                return value
            }
            let field = text(a, "field_order")
            if !field.isEmpty && field != "unknown" && fieldDisplayOrder(field) != fieldDisplayOrder(text(b, "field_order")) {
                throw Failure(message: "Проверка: изменился порядок отображения полей")
            }
            let originalFrames = Int(text(a, "nb_frames"))
            let outputFrames = Int(text(b, "nb_frames"))
            if let x = originalFrames, let y = outputFrames, x != y {
                throw Failure(message: "Проверка: изменилось число кадров (\(x) → \(y))")
            }
            if let x = Double(text(a, "duration")), let y = Double(text(b, "duration")), abs(x-y) > 0.002 {
                throw Failure(message: "Проверка: изменилась длительность видеодорожки (\(x) → \(y))")
            }
            let sourcePixel = try pixelFormat(a).0
            if text(b, "pix_fmt") != sourcePixel && !(sourcePixel == "rgb24" && text(b, "pix_fmt") == "gbrp") {
                throw Failure(message: "Проверка: изменился пиксельный формат (\(sourcePixel) → \(text(b, "pix_fmt")))")
            }
            func rotation(_ s: [String: Any]) -> Double {
                let side = s["side_data_list"] as? [[String: Any]] ?? []
                return side.compactMap { $0["rotation"] as? NSNumber }.first?.doubleValue ?? 0
            }
            if abs(rotation(a) - rotation(b)) > 0.01 { throw Failure(message: "Проверка: изменилась ориентация видео") }
        }
        let sa = streams(source, "audio"), da = streams(dest, "audio")
        if sa.count != da.count { throw Failure(message: "Проверка: изменилось количество аудиодорожек") }
        for (a, b) in zip(sa, da) {
            for key in ["sample_rate", "channels"] where text(a, key) != text(b, key) {
                throw Failure(message: "Проверка: изменился параметр аудио \(key)")
            }
        }
        if streams(source, "subtitle").count != streams(dest, "subtitle").count {
            throw Failure(message: "Проверка: изменилось количество дорожек субтитров")
        }
    }

    func compress(_ input: String) -> JobResult {
        let url = URL(fileURLWithPath: input).standardizedFileURL
        let originalSize = bytes(url)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".CMPRS-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            if isCancelled { throw Failure(message: "Отменено") }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                throw Failure(message: "Это не обычный файл")
            }
            journal.write("Исходник: \(url.path) · \(originalSize) байт")
            event("Проверка исходника…", -1)
            let source = try probe(url)
            let video = streams(source, "video")
            guard video.contains(where: { !isCover($0) }) else { throw Failure(message: "В файле нет видео") }
            let format = source["format"] as? [String: Any] ?? [:]
            let duration = Double(text(format, "duration")) ?? 0
            let mainVideo = video.first { !isCover($0) } ?? [:]
            let frameCount = Double(text(mainVideo, "nb_frames")) ?? 0
            journal.write("Видео: \(text(mainVideo, "codec_name")) \(text(mainVideo, "width"))×\(text(mainVideo, "height")) \(text(mainVideo, "pix_fmt")) · FPS \(text(mainVideo, "avg_frame_rate")) · \(duration) с")
            var args = ["-hide_banner", "-nostdin", "-n", "-loglevel", "info", "-xerror", "-noautorotate", "-i", url.path,
                        "-map", "0", "-map_metadata", "0", "-map_chapters", "0", "-copy_unknown", "-c", "copy"]
            for (i, v) in video.enumerated() where !isCover(v) {
                let (pixel, codec) = try pixelFormat(v)
                if (pixel.contains("420") && ((v["width"] as? Int ?? 0) % 2 != 0 || (v["height"] as? Int ?? 0) % 2 != 0)) ||
                    (pixel.contains("422") && (v["width"] as? Int ?? 0) % 2 != 0) {
                    throw Failure(message: "Нечётные размеры нельзя сохранить с исходной субдискретизацией в H.264")
                }
                args += ["-c:v:\(i)", codec, "-crf:v:\(i)", "24", "-preset:v:\(i)", "slow", "-b:v:\(i)", "0",
                         "-pix_fmt:v:\(i)", pixel, "-fps_mode:v:\(i)", "passthrough", "-enc_time_base:v:\(i)", "-1"]
                for (key, option) in [("color_range", "color_range"), ("color_space", "colorspace"), ("color_transfer", "color_trc"), ("color_primaries", "color_primaries")] {
                    let value = text(v, key)
                    if !value.isEmpty && value != "unknown" { args += ["-\(option):v:\(i)", value == "gbr" && key == "color_space" ? "rgb" : value] }
                }
                let range = text(v, "color_range")
                if range == "tv" || range == "pc" {
                    args += ["-bsf:v:\(i)", "h264_metadata=video_full_range_flag=\(range == "pc" ? 1 : 0)"]
                }
                let field = text(v, "field_order")
                if ["tt", "bb", "tb", "bt"].contains(field) {
                    args += ["-flags:v:\(i)", "+ilme+ildct", "-x264-params:v:\(i)", ["tt", "bt"].contains(field) ? "tff=1" : "bff=1"]
                }
            }
            // Preserve audio bit-for-bit; decode unsupported MOV audio to lossless PCM.
            let movAudio = Set(["aac", "alac", "mp3", "mp2", "ac3", "eac3", "dts", "amr_nb", "amr_wb", "adpcm_ima_qt", "mace3", "mace6", "qdm2", "qdmc"])
            for (i, a) in streams(source, "audio").enumerated() {
                let codec = text(a, "codec_name")
                if !movAudio.contains(codec) && !codec.hasPrefix("pcm_") {
                    let sampleFormat = text(a, "sample_fmt")
                    let pcm = sampleFormat.hasPrefix("dbl") ? "pcm_f64le" : sampleFormat.hasPrefix("flt") ? "pcm_f32le" : "pcm_s32le"
                    args += ["-c:a:\(i)", pcm]
                }
            }
            if streams(source, "subtitle").contains(where: { text($0, "codec_name") != "mov_text" }) {
                throw Failure(message: "Исходные субтитры нельзя без изменений поместить в MOV. Файл пропущен.")
            }
            args += ["-movflags", "+faststart+use_metadata_tags", "-progress", "pipe:1", "-nostats", "-f", "mov", temporary.path]
            event("Подготовка кадров…", -1)
            _ = try run("ffmpeg", args, duration: duration, frameCount: frameCount)
            event("Проверка результата…", 0.98)
            let destination = try probe(temporary)
            try validate(source, destination)
            let size = bytes(temporary)
            guard size > 0 else { throw Failure(message: "Результат пуст") }
            if size >= originalSize {
                return JobResult(input: url.path, status: "skipped", output: nil,
                    message: "Размер не уменьшился (\(originalSize) → \(size) байт). Дополнительный файл не сохранён.", originalBytes: originalSize, outputBytes: size)
            }
            if isCancelled { throw Failure(message: "Отменено") }
            let base = "CMPRS-" + url.deletingPathExtension().lastPathComponent
            var suffix = 1
            var final: URL
            while true {
                let name = base + (suffix == 1 ? "" : " (\(suffix))") + ".mov"
                final = url.deletingLastPathComponent().appendingPathComponent(name)
                // Atomic publication: no existing file can be overwritten, even by another batch.
                if renameatx_np(AT_FDCWD, temporary.path, AT_FDCWD, final.path, UInt32(RENAME_EXCL)) == 0 { break }
                if errno == EEXIST { suffix += 1; continue }
                throw Failure(message: "Не удалось сохранить MOV: \(String(cString: strerror(errno)))")
            }
            event("Готово", 1)
            let saving = Int((1 - Double(size) / Double(originalSize)) * 100)
            return JobResult(input: url.path, status: "ok", output: final.path,
                message: "−\(saving)% · \(final.lastPathComponent)", originalBytes: originalSize, outputBytes: size)
        } catch {
            return JobResult(input: url.path, status: isCancelled ? "cancelled" : "error", output: nil,
                message: error.localizedDescription, originalBytes: originalSize, outputBytes: 0)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @unchecked Sendable {
    let worker = Compressor()
    var window: NSWindow!
    var titleLabel: NSTextField!
    var detailLabel: NSTextField!
    var progress: NSProgressIndicator!
    var log: NSTextView!
    var button: NSButton!
    var diagnosticsButton: NSButton!
    var working = false
    var closeWhenDone = false
    var pending: [String]
    var results: [JobResult] = []

    init(_ paths: [String]) { pending = paths }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Завершить CMPRS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 440), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "CMPRS · Ironclad 100%"
        window.minSize = NSSize(width: 560, height: 360)
        window.delegate = self
        let root = NSView(); window.contentView = root
        titleLabel = NSTextField(labelWithString: "Сжатие видео · Ironclad 100%")
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        detailLabel = NSTextField(labelWithString: "CRF 24 · slow · исходные размер, FPS и глубина цвета")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        progress = NSProgressIndicator(); progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        log = NSTextView(); log.isEditable = false; log.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        log.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = log
        button = NSButton(title: "Отменить", target: self, action: #selector(cancelOrClose))
        button.bezelStyle = .rounded
        diagnosticsButton = NSButton(title: "Скопировать диагностику", target: self, action: #selector(copyDiagnostics))
        diagnosticsButton.bezelStyle = .rounded
        for view in [titleLabel!, detailLabel!, progress!, scroll, button!, diagnosticsButton!] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 22), titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 9), detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), detailLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            progress.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 16), progress.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), progress.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: progress.bottomAnchor, constant: 18), scroll.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22), scroll.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -16),
            diagnosticsButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), diagnosticsButton.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22), button.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18)
        ])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if pending.isEmpty {
            append("В Finder выделите видео → Быстрые действия → CMPRS Ironclad 100%.\nМожно выбрать несколько файлов сразу.")
            button.title = "Закрыть"
        } else { start() }
    }

    func append(_ text: String) {
        log.textStorage?.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular), .foregroundColor: NSColor.labelColor]))
        log.scrollToEndOfDocument(nil)
    }

    @objc func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worker.journal.contents(), forType: .string)
        diagnosticsButton.title = "Диагностика скопирована"
    }

    func start() {
        working = true
        let paths = pending
        let reportURL = saveReport([])
        append("Журнал: \(worker.journal.url.path)\n")
        append("Файлов в очереди: \(paths.count). Оригиналы сохраняются.\n")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Сжатие видео CMPRS")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            for (index, path) in paths.enumerated() {
                if worker.isCancelled { break }
                DispatchQueue.main.async { [self] in titleLabel.stringValue = "Файл \(index + 1) из \(paths.count)"; append(URL(fileURLWithPath: path).lastPathComponent) }
                worker.event = { [self] text, value in
                    DispatchQueue.main.async { [self] in
                        progress.isIndeterminate = value < 0
                        if value < 0 { progress.startAnimation(nil) }
                        else { progress.stopAnimation(nil); progress.doubleValue = (Double(index) + value) / Double(paths.count) }
                        detailLabel.stringValue = "\(text) · \(URL(fileURLWithPath: path).lastPathComponent)"
                    }
                }
                let result = worker.compress(path)
                results.append(result)
                worker.journal.write("Результат: \(result.status) · \(result.message)")
                saveReport(results, to: reportURL)
                DispatchQueue.main.async { [self] in append("\(result.status == "ok" ? "✓" : "•") \(result.message)\n") }
            }
            let logURL = saveReport(results, to: reportURL)
            DispatchQueue.main.async { [self] in
                working = false
                progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 1
                let ok = results.filter { $0.status == "ok" }.count
                titleLabel.stringValue = worker.isCancelled ? "Сжатие отменено" : "Обработка завершена"
                detailLabel.stringValue = "Сохранено: \(ok) · Пропущено / ошибки: \(results.count - ok) · Всего: \(paths.count)"
                if let logURL { append("Отчёт: \(logURL.path)") }
                button.title = "Закрыть"; button.isEnabled = true
                NSApp.requestUserAttention(.informationalRequest)
                if closeWhenDone { NSApp.terminate(nil) }
            }
        }
    }

    @objc func cancelOrClose() {
        if working { worker.cancel(); button.title = "Отмена…"; button.isEnabled = false }
        else { NSApp.terminate(nil) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if working { closeWhenDone = true; cancelOrClose(); return false }
        NSApp.terminate(nil); return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if working { closeWhenDone = true; cancelOrClose(); return .terminateCancel }
        return .terminateNow
    }
}

@discardableResult
func saveReport(_ results: [JobResult], to target: URL? = nil) -> URL? {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CMPRS")
    let url = target ?? folder.appendingPathComponent("\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8)).json")
    do {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(results).write(to: url, options: .atomic)
        return url
    } catch { return nil }
}

var args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
if args.first == "--register-service" {
    guard let preferences = UserDefaults(suiteName: "pbs") else { exit(1) }
    var status = preferences.dictionary(forKey: "NSServicesStatus") ?? [:]
    let key = "(null) - CMPRS Ironclad 100% - runWorkflowAsService"
    var entry = status[key] as? [String: Any] ?? [:]
    var modes = entry["presentation_modes"] as? [String: Any] ?? [:]
    for mode in ["ContextMenu", "FinderPreview", "ServicesMenu"] { modes[mode] = true }
    entry["presentation_modes"] = modes
    status[key] = entry
    preferences.set(status, forKey: "NSServicesStatus")
    preferences.synchronize()
    NSUpdateDynamicServices()
    NSSetShowsServicesMenuItem("CMPRS Ironclad 100%", true)
    exit(0)
}
if args.first == "--headless" {
    args.removeFirst()
    var report: URL?
    if args.count >= 2 && args[0] == "--report" { report = URL(fileURLWithPath: args[1]); args.removeFirst(2) }
    let engine = Compressor()
    let results = args.map { engine.compress($0) }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? encoder.encode(results) { FileHandle.standardOutput.write(data); print("") }
    if let report { saveReport(results, to: report) }
    exit(results.contains { $0.status == "error" || $0.status == "cancelled" } ? 1 : 0)
}
let app = NSApplication.shared
let delegate = AppDelegate(args)
app.delegate = delegate
app.run()
