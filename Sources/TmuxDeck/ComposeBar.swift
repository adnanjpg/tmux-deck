import AppKit
import SwiftUI

/// The message box under each window. It's a real Mac text view, so ⌘A, ⌥⌫, ⌘⌫,
/// ⌥←/→, ⌘Z and mouse selection all work. Enter sends; Shift+Enter adds a line.
/// When the box is empty, navigation keys go straight to the window so Claude's
/// menus (arrows, Enter, Esc, Tab) keep working without clicking into the terminal.
struct ComposeBar: View {
    @EnvironmentObject private var model: TmuxModel
    let window: TmuxWindow
    @State private var text = ""
    @State private var height: CGFloat = 22
    @State private var focusToken = 0
    @State private var attachments: [Attachment] = []
    @State private var dropTargeted = false

    /// A pasted or dropped image, uploaded to the work machine as soon as it's added.
    struct Attachment: Identifiable {
        let id = UUID()
        let image: NSImage
        var remotePath: String?
        var failed = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if window.state == .claudeNeedsYou, let options = model.promptOptions[window.id], !options.isEmpty {
                promptButtons(options)
            }
            if !attachments.isEmpty { attachmentStrip }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        if let suggestion {
                            HStack(spacing: 6) {
                                Text(suggestion).foregroundStyle(.tertiary).lineLimit(1)
                                Text("Tab")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
                            }
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                        } else {
                            Text(placeholder)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    ComposeTextView(text: $text, height: $height, focusToken: focusToken,
                                    suggestion: suggestion,
                                    onSubmit: submit, onForward: forward,
                                    onAcceptSuggestion: { if let suggestion { text = suggestion } },
                                    onImages: addImages)
                        .frame(height: min(max(height, 22), 160))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(dropTargeted ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: dropTargeted ? 2 : 1))

                if window.state.isClaude {
                    Button { model.send(keys: ["Escape"], to: window) } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop Claude (Esc)")
                    .controlSize(.large)
                    .disabled(window.state != .claudeWorking)
                }
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                .help("Send (Enter)")
            }
        }
        .font(.system(size: 13))
        .padding(12)
        .background(.bar)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            loadImages(from: providers)
            return true
        }
        .onAppear {
            text = model.drafts[window.id] ?? ""
            focusToken += 1
        }
        .onChange(of: text) { _, new in model.drafts[window.id] = new }
    }

    private var suggestion: String? { model.suggestions[window.id] }

    private var placeholder: String {
        window.state.isClaude
            ? "Message Claude — Enter to send, Shift+Enter for a new line"
            : "Type a command — Enter to run"
    }

    private func promptButtons(_ options: [PromptOption]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            Text("Claude is asking").font(.callout).foregroundStyle(.secondary)
            ForEach(options, id: \.key) { option in
                Button {
                    model.send(keys: [option.key], to: window, literal: true)
                } label: {
                    Text(option.label).lineLimit(1).truncationMode(.tail).frame(maxWidth: 280)
                }
                .buttonStyle(.bordered)
                .tint(option.key == "1" ? .accentColor : nil)
                .help("Answer \(option.key)")
            }
            Spacer(minLength: 0)
        }
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .newlines)
        if !attachments.isEmpty {
            if attachments.contains(where: { $0.remotePath == nil && !$0.failed }) {
                model.flash("Still uploading the image…"); return
            }
            let paths = attachments.compactMap(\.remotePath)
            model.send(text: message, images: paths, to: window)
            attachments = []
            text = ""
            return
        }
        guard !message.trimmingCharacters(in: .whitespaces).isEmpty else {
            model.send(keys: ["Enter"], to: window)
            return
        }
        model.send(text: message, to: window)
        text = ""
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    Image(nsImage: a.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(a.failed ? Color.red : Color(nsColor: .separatorColor)))
                        .overlay {
                            if a.remotePath == nil && !a.failed {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
                                    ProgressView().controlSize(.small).tint(.white)
                                }
                            } else if a.failed {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button { attachments.removeAll { $0.id == a.id } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                            .help("Remove")
                        }
                        .help(a.failed ? "Upload failed" : (a.remotePath ?? "Uploading…"))
                }
            }
        }
    }

    /// Adds images (PNG/TIFF/JPEG data) and starts uploading each one.
    private func addImages(_ datas: [Data]) {
        for data in datas {
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let attachment = Attachment(image: image)
            attachments.append(attachment)
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "")
            let name = "screenshot-\(stamp)-\(attachment.id.uuidString.prefix(4)).png"
            Task {
                let path = await Remote.upload(png, fileName: name)
                if let i = attachments.firstIndex(where: { $0.id == attachment.id }) {
                    attachments[i].remotePath = path
                    attachments[i].failed = path == nil
                }
            }
        }
        focusToken += 1
    }

    private func loadImages(from providers: [NSItemProvider]) {
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
                    DispatchQueue.main.async { addImages([data]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data else { return }
                    DispatchQueue.main.async { addImages([data]) }
                }
            }
        }
    }

    /// Keys pressed while the box is empty, as tmux key names.
    private func forward(_ keys: [String]) {
        model.send(keys: keys, to: window)
    }
}

struct ComposeTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusToken: Int
    var suggestion: String?
    var onSubmit: () -> Void
    var onForward: ([String]) -> Void
    var onAcceptSuggestion: () -> Void
    var onImages: ([Data]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = ComposeNSTextView()
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 13)
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 5
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        let coordinator = context.coordinator
        tv.onSubmit = { [weak coordinator] in coordinator?.parent.onSubmit() }
        tv.onForward = { [weak coordinator] keys in coordinator?.parent.onForward(keys) }
        tv.onAcceptSuggestion = { [weak coordinator] in coordinator?.parent.onAcceptSuggestion() }
        tv.onImages = { [weak coordinator] images in coordinator?.parent.onImages(images) }
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposeNSTextView else { return }
        tv.hasSuggestion = suggestion != nil
        if tv.string != text {
            tv.string = text
            context.coordinator.updateHeight(tv)
        }
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposeTextView
        var lastFocusToken = -1
        init(_ parent: ComposeTextView) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
            updateHeight(tv)
        }

        func updateHeight(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let h = ceil(lm.usedRect(for: tc).height)
            DispatchQueue.main.async { self.parent.height = max(h, 17) }
        }
    }
}

final class ComposeNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onForward: (([String]) -> Void)?
    var onAcceptSuggestion: (() -> Void)?
    var onImages: (([Data]) -> Void)?
    var hasSuggestion = false

    /// Image files, or raw image data when there's no text (a screenshot on the clipboard).
    static func images(from pb: NSPasteboard) -> [Data] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let images = urls.compactMap { url -> Data? in
                guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return nil }
                return data
            }
            if !images.isEmpty { return images }
        }
        if pb.string(forType: .string) != nil { return [] }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { return [data] }
        return []
    }

    override func paste(_ sender: Any?) {
        let images = Self.images(from: .general)
        if !images.isEmpty { onImages?(images); return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = Self.images(from: sender.draggingPasteboard)
        if !images.isEmpty { onImages?(images); return true }
        return super.performDragOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let empty = string.isEmpty

        // Ctrl+C always interrupts the window, like in a terminal.
        if flags == .control, event.charactersIgnoringModifiers == "c" {
            onForward?(["C-c"]); return
        }
        // Tab, Shift+Tab or → takes Claude's suggestion into the box, where you can edit it.
        if empty && hasSuggestion && (event.keyCode == 48 || (event.keyCode == 124 && flags.subtracting([.numericPad, .function]).isEmpty)) {
            onAcceptSuggestion?()
            DispatchQueue.main.async { self.moveToEndOfDocument(nil) }
            return
        }
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return
        case 53: // Esc
            onForward?(["Escape"]); return
        case 48 where flags.contains(.shift): // Shift+Tab: Claude's mode switch
            onForward?(["BTab"]); return
        default:
            break
        }
        if empty && flags.subtracting([.numericPad, .function]).isEmpty {
            let map: [UInt16: String] = [126: "Up", 125: "Down", 123: "Left", 124: "Right",
                                         48: "Tab", 51: "BSpace", 116: "PPage", 121: "NPage"]
            if let key = map[event.keyCode] { onForward?([key]); return }
        }
        super.keyDown(with: event)
    }
}
