import AppKit
import SwiftUI

/// The list shown from the menu bar: each question with its answer; click a row to copy the answer.
struct HistoryView: View {
    @ObservedObject var history: History
    @State private var copiedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("History")
                    .font(.headline)
                Spacer()
                Button("Clear") { history.clear() }
                    .buttonStyle(.borderless)
                    .disabled(history.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if history.entries.isEmpty {
                Text("No answers yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                // Short lists take only the room they need; long ones scroll.
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                }
            }
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(history.entries) { entry in
                HistoryRow(entry: entry, isCopied: copiedID == entry.id) { copy(entry) }
            }
        }
        .padding(.horizontal, 6)  // + row padding 10 = the header's 16
        .padding(.vertical, 8)
    }

    private func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.answer, forType: .string)
        copiedID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == entry.id { copiedID = nil }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let isCopied: Bool
    let copy: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.question)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.answer)
                        .font(.body.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.callout)
                    .foregroundStyle(isCopied ? Color.accentColor : Color.secondary)
                    .opacity(isHovered || isCopied ? 1 : 0)
                    .frame(width: 18)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
