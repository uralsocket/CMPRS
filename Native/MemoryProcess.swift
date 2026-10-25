import Foundation
import Darwin

// Child stdout/stderr exist only in bounded RAM. Nonblocking reads never wait for
// EOF (including a descriptor inherited by a child); cancellation stays responsive.
enum MemoryProcess {
    static func run(binary: URL, arguments: [String], cancelled: () -> Bool,
                    idleLimit: TimeInterval, isProbe: Bool, duration: Double = 0,
                    frameCount: Double = 0, childChanged: (Process?) -> Void = { _ in },
                    event: (String, Double) -> Void = { _, _ in }) throws -> Data {
        if cancelled() { throw Failure(message: "Cancelled.") }
        let output = Pipe(), errors = Pipe(), child = Process()
        child.executableURL = binary; child.arguments = arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = errors
        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        for handle in handles {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw Failure(message: "Unable to prepare encoder pipes.")
            }
        }
        defer {
            if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            childChanged(nil)
            for handle in handles + [output.fileHandleForWriting, errors.fileHandleForWriting] { try? handle.close() }
        }
        try child.run(); childChanged(child)
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let start = ProcessInfo.processInfo.systemUptime
        var changed = start, lastUI = start - 1
        var stopAt: TimeInterval?, failure: String?
        var probe = Data(), pending = Data()
        var fields: [String: String] = [:]
        var lastFrame = 0.0, lastTime = 0.0, lastSize: Int64 = 0
        var scratch = [UInt8](repeating: 0, count: 16_384)
        func drain(_ fd: Int32, consume: (Data) throws -> Void) throws {
            // Bound work per tick so a noisy process cannot prevent cancellation.
            for _ in 0..<64 {
                let count = Darwin.read(fd, &scratch, scratch.count)
                if count > 0 { try consume(Data(scratch.prefix(count))) }
                else if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
                else if errno != EINTR { throw Failure(message: "Unable to read encoder output.") }
            }
        }
        func readAvailable() throws {
            try drain(output.fileHandleForReading.fileDescriptor) { data in
                if isProbe {
                    guard probe.count + data.count <= 8_000_000 else { throw Failure(message: "Source metadata exceeds the safe limit.") }
                    probe.append(data); changed = ProcessInfo.processInfo.systemUptime
                } else {
                    pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<end], as: UTF8.self); pending.removeSubrange(...end)
                        let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                        if pair.count == 2, ["frame", "out_time_us", "total_size", "progress"].contains(String(pair[0])) {
                            fields[String(pair[0])] = String(pair[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    if pending.count > 65_536 { throw Failure(message: "Invalid encoder progress output.") }
                }
            }
            // FFmpeg diagnostics are consumed and discarded, never retained or saved.
            try drain(errors.fileHandleForReading.fileDescriptor) { _ in }

        }
        while true {
            try readAvailable()
            let now = ProcessInfo.processInfo.systemUptime
            let frame = Double(fields["frame"] ?? "") ?? 0
            let time = (Double(fields["out_time_us"] ?? "") ?? 0) / 1_000_000
            let size = Int64(fields["total_size"] ?? "") ?? 0
            if frame > lastFrame || time > lastTime || size > lastSize {
                changed = now; lastFrame = max(frame, lastFrame); lastTime = max(time, lastTime); lastSize = max(size, lastSize)
            }
            if now - lastUI >= 0.2 {
                let fraction = duration > 0 ? time / duration : frameCount > 0 ? frame / frameCount : 0
                event(isProbe ? "inspecting" : "encoding", isProbe ? -1 : min(0.97, max(0, fraction)))
                lastUI = now
            }
            guard child.isRunning else { break }
            if stopAt == nil {
                if cancelled() { failure = "Cancelled." }
                else if now - changed > idleLimit { failure = isProbe ? "Reading the source timed out." : "The encoder stopped making progress. Original unchanged." }
                if failure != nil { stopAt = now; if child.isRunning { child.terminate() } }
            } else if now - stopAt! >= 3, child.isRunning { kill(child.processIdentifier, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        child.waitUntilExit(); try readAvailable()
        if cancelled() { throw Failure(message: "Cancelled.") }
        if let failure { throw Failure(message: failure) }
        guard child.terminationStatus == 0 else {
            throw Failure(message: isProbe ? "Unable to read this video. Original unchanged." : "Unable to compress this video (encoder code \(child.terminationStatus)). Original unchanged.")

        }
        return probe
    }
}
