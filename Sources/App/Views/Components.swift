import AppKit
import SwiftUI

/// A code block with a copy affordance.
///
/// Every rescued asset in a debrief is either a prompt to paste into a chat or a
/// snippet to paste into a terminal, so a copy button is not decoration here — it
/// is the difference between an asset and a chore. The confirmation is transient
/// and marks only the card that was clicked.
struct CodeBlockCard: View {

    let code: String
    let language: String
    var showCopy: Bool = true
    @Binding var copiedAssetID: String?

    /// Identity for the "Copied!" state. The code itself is the identity, so a
    /// re-render never lands the tick on the wrong card.
    private var assetID: String { code }

    private var isCopied: Bool { copiedAssetID == assetID }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showCopy || !language.isEmpty {
                HStack(spacing: 8) {
                    if !language.isEmpty {
                        Text(language)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if showCopy {
                        Button {
                            copy()
                        } label: {
                            Label(
                                isCopied ? "Copied!" : "Copy",
                                systemImage: isCopied ? "checkmark" : "doc.on.doc"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isCopied ? Color.green : Color.secondary)
                            .contentTransition(.symbolEffect(.replace))
                        }
                        .buttonStyle(.borderless)
                        .help("Copy this asset to the clipboard")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.04))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(nil)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(code, forType: .string)
        copiedAssetID = assetID

        Task {
            // Transient by design: leaving the tick up would either lie, or force
            // the user to dismiss it.
            try? await Task.sleep(for: .seconds(1.6))
            if copiedAssetID == assetID { copiedAssetID = nil }
        }
    }
}

/// A three-bar level animation, so the bar is visibly alive while speaking.
struct SpeakingIndicator: View {
    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: barHeight(for: index))
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: isAnimating
                    )
            }
        }
        .onAppear { isAnimating = true }
        .accessibilityLabel("Speaking")
    }

    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [8, 14, 10]
        return isAnimating ? heights[index] : 6
    }
}

/// A grid for the rare Markdown table.
struct TableGrid: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(verbatim: header)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(verbatim: cell)
                            .font(.callout)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
