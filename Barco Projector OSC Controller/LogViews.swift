import AppKit
import SwiftUI

/// Read-only, selectable, monospaced text that always scrolls to the newest line.
struct LogTextView: NSViewRepresentable {
    let text: String

    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let inset = NSSize(width: 4, height: 4)

    static func height(forLines lines: Int) -> CGFloat {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return ceil(lineHeight * CGFloat(lines) + inset.height * 2 + 4)   // + bezel border
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.font = Self.font
            textView.textColor = .textColor
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = Self.inset
            textView.string = text
            textView.scrollToEndOfDocument(nil)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let current = textView.string
        guard current != text else { return }
        if !current.isEmpty, !text.isEmpty, let storage = textView.textStorage {
            // Replace only the part that changed (new lines at the end, or a line rewritten in place);
            // much faster than replacing a long log.
            let old = Array(current.utf16), new = Array(text.utf16)
            var prefix = 0
            while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < old.count - prefix, suffix < new.count - prefix,
                  old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            let replacement = (text as NSString).substring(with: NSRange(location: prefix, length: new.count - prefix - suffix))
            storage.replaceCharacters(in: NSRange(location: prefix, length: old.count - prefix - suffix),
                                      with: NSAttributedString(string: replacement,
                                                               attributes: [.font: Self.font, .foregroundColor: NSColor.textColor]))
        } else {
            textView.string = text
        }
        textView.scrollToEndOfDocument(nil)
    }
}

/// "Log" title, Clear and Save... buttons, the log text, and a grip to resize it.
struct LogPanel: View {
    let title: String
    let text: String
    @Binding var height: CGFloat
    let onClear: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Clear", action: onClear)
                Button("Save...", action: onSave)
            }
            LogTextView(text: text)
                .frame(height: height)
            ResizeGrip(height: $height,
                       range: LogTextView.height(forLines: 3)...LogTextView.height(forLines: 60))
        }
    }
}

/// Drag down to make the log taller, up to make it shorter. The window grows and shrinks with it.
struct ResizeGrip: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>

    @State private var dragStartHeight: CGFloat?
    @State private var dragStartMouseY: CGFloat?

    var body: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.45))
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // Screen coordinates, so the window resizing under the mouse doesn't skew the drag.
                        let mouseY = NSEvent.mouseLocation.y
                        if dragStartHeight == nil {
                            dragStartHeight = height
                            dragStartMouseY = mouseY
                        }
                        guard let startHeight = dragStartHeight, let startY = dragStartMouseY else { return }
                        // Screen y grows upward, so dragging down (smaller y) makes the log taller.
                        let proposed = startHeight + (startY - mouseY)
                        height = min(max(proposed, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                        dragStartMouseY = nil
                    }
            )
            .help("Drag to resize the log")
    }
}

/// The separate window for "Log Sent Projector Commands".
struct CommandLogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Log Sent Projector Commands", isOn: $model.logProjectorCommands)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Clear") { model.clearCommandLog() }
                Button("Save...") {
                    model.saveLog(model.commandLogText, suggestedName: "Barco Projector Commands")
                }
            }
            Text("→ sent to projector    ← received from projector")
                .font(.caption)
                .foregroundStyle(.secondary)
            LogTextView(text: model.commandLogText)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 260)
    }
}
