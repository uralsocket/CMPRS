import Foundation

enum CompressionMode: String, Codable { case compatible, smaller }
enum ContainerFormat: String, Codable { case mov }
struct NativeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
func fileBytes(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
}
struct EngineEvent: Codable {
    var type: String
    var stage: String?
    var progress: Double?
    var frames: Int?
    var message: String?
    var status: String?
    var output: String?
    var inputBytes: Int64?
    var outputBytes: Int64?
    var depth: Int?
    var hardware: Bool?
}
