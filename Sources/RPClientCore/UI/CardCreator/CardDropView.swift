import AppKit
import UniformTypeIdentifiers

/// Phase 9 §5.3d.2 — root NSView for the Card Creator window. Accepts
/// drag-dropped `.png` / `.json` card files and forwards the URL to the
/// `onCardFileDropped` closure. The view controller decides what to do
/// with the dropped file (currently: open it as Import & Edit in a new
/// creator window).
///
/// File types — restricts to PNG and JSON (the two formats
/// `CharacterCardImporter` understands). Other drops are rejected so
/// arbitrary files don't trigger an import attempt + error alert.
final class CardDropView: NSView {

    var onCardFileDropped: ((URL) -> Void)?

    private let acceptedTypes: [UTType] = [.png, .json]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return acceptedURL(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = acceptedURL(sender) else { return false }
        onCardFileDropped?(url)
        return true
    }

    private func acceptedURL(_ info: NSDraggingInfo) -> URL? {
        guard let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first(where: { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
            return acceptedTypes.contains(where: { type.conforms(to: $0) })
        })
    }
}
