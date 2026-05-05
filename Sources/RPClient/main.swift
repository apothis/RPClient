import AppKit
import RPClientCore
import RPClientVoice

// Phase 6 §7.1 sub-step a — log ONNX Runtime version at launch so the binary
// dependency wiring is visible without inspecting Mach-O linkage.
FileHandle.standardError.write(
    Data("voice: ONNX Runtime \(onnxRuntimeVersion() ?? "<unavailable>")\n".utf8)
)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
