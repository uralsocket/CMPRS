import Foundation

final class EngineRunner: @unchecked Sendable {
    private let compressor: Compressor
    init(binary: URL, probeTimeout: TimeInterval = 60, idleTimeout: TimeInterval = 300) {
        compressor = Compressor(bin: binary, probeIdleLimit: probeTimeout, encodeIdleLimit: idleTimeout)
    }
    func cancel() { compressor.cancel() }
    var isCancelled: Bool { compressor.isCancelled }
    func run(_ input: URL, mode: CompressionMode, container: ContainerFormat, allow8Bit: Bool, event: @escaping (EngineEvent) -> Void) throws -> EngineEvent {
        compressor.allow8Bit = allow8Bit
        var verifying = false
        compressor.event = { text, fraction in
            if text.contains("результата") { verifying = true }
            let stage = text == "inspecting" || text.contains("исходника") || text.contains("параметров") ? "inspecting" : text.contains("результата") ? "verifying" : "encoding"
            event(EngineEvent(type: "progress", stage: verifying ? "verifying" : stage, progress: verifying ? 0.98 : max(0, fraction)))
        }
        let result = compressor.compress(input.path)
        return EngineEvent(type: "result", message: localizedEngineMessage(result.message), status: result.status, output: result.output, inputBytes: result.originalBytes, outputBytes: result.outputBytes)
    }
}
