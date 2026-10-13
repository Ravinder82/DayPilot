import SwiftUI

/// The debrief editor.
///
/// Rendered by default, because a debrief is read before it is changed. The
/// source view is the same text as Markdown, one toggle away. Edits write back to
/// the archived file a moment after typing stops, so the file on disk is the
/// document and there is no save step to forget.
struct ReportEditorView: View {

    @ObservedObject private var model: AppModel
    @State private var copiedAssetID: String?

    init(model: AppModel) {
        _model = ObservedObject(wrappedValue: model)
    }

    private var document: MarkdownDocument {
        MarkdownDocument(markdown: model.reportBody)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.isEditingSource {
                    sourceEditor
                } else if model.reportBody.isEmpty {
                    emptyState
                } else {
                    renderedReport
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.canSpeakCurrentDebrief {
                AudioBar(model: model)
            }
        }
        .navigationTitle(model.detailTitle)
        .navigationSubtitle(model.detailSubtitle)
        .alert("The report could not be saved", isPresented: writeErrorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.reportWriteError ?? "")
        }
    }

    private var writeErrorIsPresented: Binding<Bool> {
        Binding(
            get: { model.reportWriteError != nil },
            set: { if !$0 { model.clearReportWriteError() } }
        )
    }

    // MARK: - Source

    private var sourceEditor: some View {
        TextEditor(text: $model.reportBody)
            .font(.system(.body, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(16)
            .background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("Report Markdown source")
            .disabled(!model.reportBodyIsEditable)
    }

    // MARK: - Rendered

    private var renderedReport: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Returns `AnyView` because a block can contain blocks. SwiftUI cannot infer
    /// a recursive `some View`, and quotes, list items and table cells all nest.
    /// This is the one place erasure is the right call, at the recursion boundary.
    private func blockView(_ block: MarkdownDocument.Block) -> AnyView {
        AnyView(renderBlock(block))
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownDocument.Block) -> some View {
        switch block {
        case .heading(let level, let inline):
            inlineText(inline)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level <= 2 ? 18 : 12)
                .padding(.bottom, 6)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

        case .paragraph(let inline):
            inlineText(inline)
                .font(.body)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
                .textSelection(.enabled)

        case .codeBlock(let language, let code):
            CodeBlockCard(code: code, language: language, copiedAssetID: $copiedAssetID)
                .padding(.bottom, 14)

        case .divider:
            Divider()
                .padding(.vertical, 12)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        itemStack(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        itemStack(item)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)

        case .quote(let children):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                itemStack(children)
            }
            .padding(.bottom, 10)

        case .table(let headers, let rows):
            TableGrid(headers: headers, rows: rows)
                .padding(.bottom, 14)
        }
    }

    private func itemStack(_ blocks: [MarkdownDocument.Block]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, child in
                blockView(child)
            }
        }
    }

    /// Composes inline runs into one `Text`, using native concatenation rather
    /// than `AttributedString`: it stays in SwiftUI's own domain and handles nested
    /// emphasis directly. Author text uses `Text(verbatim:)` so it is never looked
    /// up as a localisation key.
    private func inlineText(_ inline: [MarkdownDocument.Inline]) -> Text {
        var result: Text?
        for run in inline {
            let piece: Text
            switch run {
            case .text(let value):
                piece = Text(verbatim: value)
            case .bold(let children):
                piece = inlineText(children).bold()
            case .italic(let children):
                piece = inlineText(children).italic()
            case .code(let value):
                piece = Text(verbatim: value).font(.body.monospaced())
            case .link(let label, _):
                piece = Text(verbatim: label)
                    .foregroundColor(.accentColor)
                    .underline()
            }
            result = result.map { $0 + piece } ?? piece
        }
        return result ?? Text(verbatim: "")
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 0, 1: return .largeTitle.weight(.bold)
        case 2: return .title2.weight(.semibold)
        case 3: return .title3.weight(.semibold)
        case 4: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(model.emptyStateTitle)
                .font(.title3.weight(.semibold))

            Text(model.emptyStateMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if !model.hasAnyProviderKey {
                SettingsLink {
                    Label("Connect an AI Provider…", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Playback controls for the current debrief, with a live speaking indicator.
private struct AudioBar: View {

    @ObservedObject var model: AppModel

    private var playSymbol: String {
        model.isSpeaking && !model.isPaused ? "pause.fill" : "play.fill"
    }

    private var playHelp: String {
        if model.isSpeaking && !model.isPaused { return "Pause" }
        if model.isPaused { return "Resume" }
        return "Play the spoken debrief"
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 16) {
                Button {
                    model.stopPlayback()
                    model.speakDebrief()
                } label: {
                    Image(systemName: "gobackward")
                }
                .help("Play from the beginning")
                .accessibilityLabel("Play from the beginning")

                Button(action: togglePlayback) {
                    Image(systemName: playSymbol)
                        .font(.title2)
                        .frame(width: 30, height: 30)
                }
                .help(playHelp)
                .accessibilityLabel(playHelp)

                Button {
                    model.stopPlayback()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop")
                .accessibilityLabel("Stop")
                .disabled(!model.isSpeaking && !model.isPaused)

                if model.isSpeaking {
                    SpeakingIndicator()
                }

                Spacer()

                Text(model.voiceSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial)
    }

    private func togglePlayback() {
        if model.isPaused {
            model.resumePlayback()
        } else if model.isSpeaking {
            model.pausePlayback()
        } else {
            model.speakDebrief()
        }
    }
}
