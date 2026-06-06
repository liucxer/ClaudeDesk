import SwiftUI
import AppKit

struct ChatTextEditor: NSViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var onSubmit: () -> Void
    /// Called with the raw image bytes whenever the user pastes an image into
    /// the editor — composer saves them to the attachments dir and shows a
    /// thumbnail chip.
    var onImagesPasted: ([Data]) -> Void = { _ in }

    func makeNSView(context: Context) -> NSScrollView {
        // Build an NSScrollView around our PasteAwareTextView so it can
        // intercept image paste while still behaving like a normal editor.
        let textView = PasteAwareTextView()
        textView.onImagesPasted = onImagesPasted

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        textView.autoresizingMask = [.width]

        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PasteAwareTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.onImagesPasted = onImagesPasted
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextEditor
        init(_ parent: ChatTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                if shiftHeld {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    return true
                }
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// NSTextView subclass that intercepts paste when the pasteboard contains
/// image data — we hand the bytes off to the composer instead of inserting a
/// rich-text image into a plain-text editor. Plain-text paste still goes
/// through the default code path.
final class PasteAwareTextView: NSTextView {
    var onImagesPasted: ([Data]) -> Void = { _ in }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let datas = Self.readImageData(from: pb), !datas.isEmpty {
            onImagesPasted(datas)
            return
        }
        super.paste(sender)
    }

    static func readImageData(from pb: NSPasteboard) -> [Data]? {
        // 1) File URLs that point at images
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let imageURLs = urls.filter { Self.isImageURL($0) }
            if !imageURLs.isEmpty {
                return imageURLs.compactMap { try? Data(contentsOf: $0) }
            }
        }
        // 2) Direct image data (e.g. ⌘⇧4 screen capture, copied from Preview)
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           !imgs.isEmpty {
            return imgs.compactMap { Self.pngData(from: $0) }
        }
        return nil
    }

    static func isImageURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(ext)
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
