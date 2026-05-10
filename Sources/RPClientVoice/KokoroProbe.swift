import Foundation
import OnnxRuntimeBindings

/// One-shot introspection of a Kokoro `model.onnx` — opens a session and
/// returns the input and output tensor names. Phase 6 §7.1k3 prep: confirms
/// the model is the "newer export" with `input_ids` (vs. the older `tokens`
/// path) before `KokoroEngine` is written, since that distinction changes
/// which code path in upstream `kokoro-onnx` is the reference for our types.
///
/// The Swift/Obj-C ORT bindings don't surface per-input element type or
/// shape from the model schema (only from runtime `ORTValue`s), so this is
/// the best schema introspection these bindings allow without parsing the
/// ONNX protobuf directly.
public struct KokoroProbeResult {
    public let inputNames: [String]
    public let outputNames: [String]
}

public enum KokoroProbeError: Error {
    case sessionOpenFailed(String)
    case introspectionFailed(String)
}

public func probeKokoroSession(modelURL: URL) throws -> KokoroProbeResult {
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    let session: ORTSession
    do {
        session = try ORTSession(
            env: env,
            modelPath: modelURL.path,
            sessionOptions: options
        )
    } catch {
        throw KokoroProbeError.sessionOpenFailed(String(describing: error))
    }

    do {
        let inputs = try session.inputNames()
        let outputs = try session.outputNames()
        return KokoroProbeResult(inputNames: inputs, outputNames: outputs)
    } catch {
        throw KokoroProbeError.introspectionFailed(String(describing: error))
    }
}
