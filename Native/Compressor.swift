import Foundation
import Darwin

// Ironclad quality=100: compressO ffmpeg.rs, CRF = 24, preset = slow.
// Compatible 4:2:0 output; reducing source bit depth requires explicit consent.
struct JobResult: Codable {
    let input: String
    let status: String
    let output: String?
    let message: String
    let originalBytes: Int64
    let outputBytes: Int64
}

struct DepthConsentRequired: Error {}

struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { localizedEngineMessage(message) }
}

final class Compressor: @unchecked Sendable {
    let bin: URL
    var allow8Bit = false
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
        try MemoryProcess.run(binary: bin.appendingPathComponent(tool), arguments: args,
            cancelled: { self.isCancelled }, idleLimit: tool == "ffprobe" ? probeIdleLimit : encodeIdleLimit,
            isProbe: tool == "ffprobe", duration: duration, frameCount: frameCount,
            childChanged: { process in self.lock.lock(); self.child = process; self.lock.unlock() },
            event: event)
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
        let supported = ["yuv420p", "yuvj420p", "yuv422p", "yuvj422p", "yuv444p", "yuvj444p", "yuv420p10le", "yuv422p10le", "yuv444p10le", "yuv444p12le", "yuv422p12le", "gray", "gray10le", "nv12", "nv16", "p010le", "p012le", "rgb24", "bgr24", "gbrp", "gbrp10le", "gbrp12le"]
        guard supported.contains(pixel) else { throw Failure(message: "Unsupported source pixel format: \(pixel). Original unchanged.") }
        let highDepth = pixel.contains("10") || pixel.contains("12") || pixel.contains("16") && pixel != "nv16"
        if highDepth && !allow8Bit { throw DepthConsentRequired() }
        return (text(s, "color_range") == "pc" ? "yuvj420p" : "yuv420p", "libx264")
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
            event("Проверка исходника…", -1)
            let source = try probe(url)
            let video = streams(source, "video")
            guard video.contains(where: { !isCover($0) }) else { throw Failure(message: "В файле нет видео") }
            let format = source["format"] as? [String: Any] ?? [:]
            let duration = Double(text(format, "duration")) ?? 0
            let mainVideo = video.first { !isCover($0) } ?? [:]
            let frameCount = Double(text(mainVideo, "nb_frames")) ?? 0
            var args = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-xerror", "-noautorotate", "-i", url.path,
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
            for (i, a) in streams(source, "audio").enumerated() where text(a, "codec_name") != "aac" {
                let channels = max(1, Int(text(a, "channels")) ?? 2)
                args += ["-c:a:\(i)", "aac", "-b:a:\(i)", "\(min(512, channels * 96))k"]
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
        } catch is DepthConsentRequired {
            return JobResult(input: url.path, status: "needs-consent", output: nil, message: "8-bit conversion is required for broad H.264 playback.", originalBytes: originalSize, outputBytes: 0)
        } catch {
            return JobResult(input: url.path, status: isCancelled ? "cancelled" : "error", output: nil,
                message: error.localizedDescription, originalBytes: originalSize, outputBytes: 0)
        }
    }
}

func localizedEngineMessage(_ message: String) -> String {
    let russian = Bundle.main.preferredLocalizations.first == "ru"
    let replacements: [(String, String)] = russian ? [
        ("Cancelled.", "Отменено"),
        ("Unable to read this video. Original unchanged.", "Не удалось прочитать видео. Оригинал сохранён."),
        ("Unable to compress this video (encoder code ", "Не удалось сжать видео (код "),
        ("). Original unchanged.", "). Оригинал сохранён."),
        ("Unsupported source pixel format: ", "Неподдерживаемый пиксельный формат: "),
        ("Reading the source timed out.", "Не удалось прочитать исходник: превышено время ожидания."),
        ("The encoder stopped making progress. Original unchanged.", "Кодировщик перестал продвигаться. Оригинал сохранён."),
        ("8-bit conversion is required for broad H.264 playback.", "Для совместимого H.264 нужен переход в 8 бит.")
    ] : [
        ("Не удалось прочитать параметры файла", "Unable to read source metadata"),
        ("HDR / Dolby Vision: Ironclad H.264 не сохраняет все HDR-метаданные. Файл пропущен без изменения.", "HDR / Dolby Vision metadata cannot be preserved in Ironclad H.264. Original unchanged."),
        ("Видео с прозрачностью: Ironclad H.264 не поддерживает alpha. Файл пропущен без изменения.", "H.264 does not support transparency. Original unchanged."),
        ("Проверка: изменилось количество видеодорожек", "Validation: video track count changed"),
        ("Проверка: изменился порядок отображения полей", "Validation: field display order changed"),
        ("Проверка: изменилась ориентация видео", "Validation: orientation changed"),
        ("Проверка: изменилось количество аудиодорожек", "Validation: audio track count changed"),
        ("Проверка: изменилось количество дорожек субтитров", "Validation: subtitle track count changed"),
        ("Это не обычный файл", "Not a regular file"),
        ("В файле нет видео", "No video track found"),
        ("Нечётные размеры нельзя сохранить с исходной субдискретизацией в H.264", "Odd dimensions cannot be preserved in compatible H.264"),
        ("Исходные субтитры нельзя без изменений поместить в MOV. Файл пропущен.", "Source subtitles cannot be preserved in MOV. Original unchanged."),
        ("Результат пуст", "The output is empty"),
        ("Отменено", "Cancelled."),
        ("Проверка: параметр ", "Validation: parameter "),
        (" изменился с ", " changed from "),
        (" на ", " to "),
        ("Проверка: изменилось число кадров", "Validation: frame count changed"),
        ("Проверка: изменилась длительность видеодорожки", "Validation: video duration changed"),
        ("Проверка: изменился пиксельный формат", "Validation: pixel format changed"),
        ("Проверка: изменился параметр аудио ", "Validation: audio parameter changed: "),
        ("Размер не уменьшился (", "File size did not decrease ("),
        (" байт). Дополнительный файл не сохранён.", " bytes). No additional file was saved."),
        ("Не удалось сохранить MOV: ", "Unable to save MOV: ")
    ]
    return replacements.reduce(message) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
}
