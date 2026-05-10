import Foundation
import RPClientVoice

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: KokoroProbe <path-to-model.onnx>\n".utf8))
    exit(2)
}
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

print("ONNX Runtime version: \(onnxRuntimeVersion() ?? "<unavailable>")")
print("Model: \(url.path)")

do {
    let result = try probeKokoroSession(modelURL: url)
    print("Inputs:")
    for name in result.inputNames { print("  - \(name)") }
    print("Outputs:")
    for name in result.outputNames { print("  - \(name)") }
} catch {
    FileHandle.standardError.write(Data("probe failed: \(error)\n".utf8))
    exit(1)
}
