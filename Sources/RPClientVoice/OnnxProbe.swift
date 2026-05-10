import Foundation
import OnnxRuntimeBindings

/// Returns the ONNX Runtime version string (e.g. "1.24.2"), or nil if the
/// runtime hasn't been linked correctly. Phase 6 §7.1 sub-step a — exists so
/// the executable can prove the binary dependency wired up at launch before
/// any real synthesis code lands.
public func onnxRuntimeVersion() -> String? {
    ORTVersion()
}
