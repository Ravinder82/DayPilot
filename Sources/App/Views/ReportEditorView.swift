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
    @State private var showSessionInfo = false

    /// Headings that begin the session record rather than the brief.
    ///
    /// The app appends provenance to every archived file so a report can be
    /// audited later, and older reports also trail the voice script and the
    /// rules that were harvested. That is bookkeeping, not the debrief, so it
    /// opens behind one control instead of sitting under the last section.
    private static let sessionRecordHeadings = [
        "provenance",
        "voice script",
        "rules of thumb",
        "added to your working profile",
    ]

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
                    if isFreshState {
                        welcomeState
                    } else {
                        emptyState
                    }
                } else {
                    renderedReport
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Axo lives in a reserved strip on the trailing edge — project
        // condition: floating UI sits in its own reserved space, content never
        // scrolls beneath it, and it never covers controls. The safe-area inset
        // keeps the report's text column out of the strip, so nothing can pass
        // under him. Invisible to clicks, so selection keeps working underneath.
        .safeAreaInset(edge: .trailing, alignment: .bottom) {
            if !model.reportBody.isEmpty {
                AxoStageView()
                    .frame(width: 195, height: 195)
                    .padding(.trailing, 18)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(model.detailTitle)
        .navigationSubtitle(model.detailSubtitle)
        // A fresh report opens with its record closed: provenance is there when
        // it is asked for, never the first thing on the page.
        .onChange(of: model.selectedSessionID) { _, _ in
            showSessionInfo = false
        }
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
        let split = sessionRecordSplit
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(split.body.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
                if let record = split.record, !record.isEmpty {
                    sessionInfoDisclosure(record)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The brief, and the session record that trails it.
    ///
    /// Everything from the first record heading to the end of the document is
    /// split off. Reports written before the app added provenance still get the
    /// same treatment, and a brief with no record at all renders whole.
    private var sessionRecordSplit: (body: [MarkdownDocument.Block], record: [MarkdownDocument.Block]?) {
        let blocks = document.blocks
        guard var cut = blocks.firstIndex(where: isSessionRecordHeading) else {
            return (blocks, nil)
        }
        // Reports written before the archive dropped its separator still carry
        // a rule above the provenance; it belongs with the record, so it goes
        // behind the disclosure instead of sitting on the page.
        if cut > 0, case .divider = blocks[cut - 1] {
            cut -= 1
        }
        return (Array(blocks[..<cut]), Array(blocks[cut...]))
    }

    private func isSessionRecordHeading(_ block: MarkdownDocument.Block) -> Bool {
        guard case .heading(_, let inline) = block else { return false }
        let heading = plainText(inline).lowercased()
        return Self.sessionRecordHeadings.contains { heading.contains($0) }
    }

    /// The record behind one click. Collapsed, it costs a single row; opened,
    /// it is the full provenance list rendered like any other block.
    private func sessionInfoDisclosure(_ blocks: [MarkdownDocument.Block]) -> some View {
        DisclosureGroup(isExpanded: $showSessionInfo) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .padding(.top, 4)
        } label: {
            Label("Session Info", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHint("Shows the session record: provenance, timing and capture detail")
    }

    /// The plain words of an inline run, used to read heading text.
    private func plainText(_ inline: [MarkdownDocument.Inline]) -> String {
        inline.map { run in
            switch run {
            case .text(let value):
                return value
            case .bold(let children), .italic(let children):
                return plainText(children)
            case .code(let value):
                return value
            case .link(let label, _):
                return label
            }
        }
        .joined()
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
                Button {
                    model.mainTab = .settings
                } label: {
                    Label("Connect an AI Provider…", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
                .help("Open Settings")
            }

            Button {
                Task { await model.loadSampleDayBrief() }
            } label: {
                Label("Load a sample Day Brief", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .help("Write a sample Day Brief into the library, so there is a report to read")
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Welcome (fresh state)

    /// True only on a fresh install: nothing captured, no debrief to show.
    /// That is the screen Axo greets on — every other empty case keeps the
    /// quiet "No debrief yet" state.
    private var isFreshState: Bool {
        model.reportBody.isEmpty && model.storedSessions.isEmpty
    }

    /// Axo's own colour, taken from the mascot rather than from a picker, so
    /// the stage and the copy read as one screen.
    private static let axoMint = Color(red: 0.31, green: 0.82, blue: 0.75)

    /// The greeting screen.
    ///
    /// Two columns, because the mascot is the subject and deserves the room:
    /// Axo stands in his own light on the left, the copy is left-aligned on
    /// the right. Stacking the figure *above* the text is what made the old
    /// screen run past the bottom of the window — the figure now costs the
    /// layout no vertical space at all, and the whole composition stays
    /// centred however tall the window is.
    ///
    /// Every line here is bounded by a `maxWidth` and nothing uses
    /// `fixedSize(horizontal: false, vertical: true)`. That modifier asks a
    /// `Text` for its ideal height, and SwiftUI answers it by re-proposing a
    /// near-zero width, so a wrapped line comes back as one character per
    /// row: the greeting alone measured 6,763 pt tall, tall enough that
    /// SwiftUI never placed the window on screen at all. Bounding the width
    /// instead lets the text wrap and keeps the ideal size honest.
    ///
    /// The three steps are the daily loop. A connecting rail was tried and
    /// cut again — a `Rectangle` constrained in width but not height absorbs
    /// the full height the stack proposes, so the rail stretched the rows
    /// until the last steps fell off the window. The sequence reads from the
    /// copy itself, "Press ▶" through "Press ■", and needs no drawn line.
    private var welcomeState: some View {
        HStack(alignment: .center, spacing: 0) {
            welcomeStage

            VStack(alignment: .leading, spacing: 0) {
                Text("Welcome to DayPilot")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(-0.5)

                Text("Your workday, captured quietly — and written up as a brief you can act on.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .padding(.top, 8)
                    .frame(maxWidth: 400, alignment: .leading)

                VStack(alignment: .leading, spacing: 20) {
                    welcomeStep("Start your workday",
                                "Press ▶. Axo wakes up and DayPilot starts watching your work — screen text only, never video.")
                    welcomeStep("Work as usual",
                                "Code, browse, build. Your apps, windows and lines of text are captured quietly in the background.")
                    welcomeStep("Stop for your Day Brief",
                                "Press ■. DayPilot writes where the time went, what moved, and tomorrow's first move.")
                }
                .padding(.top, 26)

                Text("Open the Memory tab to add a folder — every file your AI memory can reach, in one browser.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(2)
                    .padding(.top, 24)
                    .frame(maxWidth: 400, alignment: .leading)

                if !model.hasAnyProviderKey {
                    Button {
                        model.mainTab = .settings
                    } label: {
                        Label("Connect an AI Provider…", systemImage: "key.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 22)
                    .help("Open Settings")
                }

                Button {
                    Task { await model.loadSampleDayBrief() }
                } label: {
                    Label("Load a sample Day Brief", systemImage: "doc.text")
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .help("Write a sample Day Brief into the library, so there is a report to read")
            }
            .frame(maxWidth: 440, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { greetOnArrival() }
    }

    /// Axo's stage: the figure at a size that reads as the subject, sitting in
    /// a low pool of his own light. No panel and no card behind him — the glow
    /// and the contact shadow the scene already draws are the only edge he
    /// gets, so he reads as lit rather than boxed.
    private var welcomeStage: some View {
        ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Self.axoMint.opacity(0.26), Self.axoMint.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 118
                    )
                )
                .frame(width: 280, height: 280)

            AxoStageView()
                .frame(width: 250, height: 250)
        }
        // Fixed in both axes. The stage wraps an `SCNView`, whose intrinsic
        // size is not ours to predict: left unconstrained it dragged the whole
        // greeting's ideal height into the thousands of points, which is what
        // stopped SwiftUI from ever placing the window on screen.
        .frame(width: 300, height: 320)
        .fixedSize()
        .accessibilityElement()
        .accessibilityLabel("Axo, the DayPilot mascot")
    }

    /// One step of the daily loop.
    ///
    /// The mint dot is the only marker. A connecting rail was tried first and
    /// cut again: a `Rectangle` constrained in width but not height absorbs the
    /// full height the stack proposes, so the rail stretched the rows until the
    /// title and the last steps fell off the window. The sequence reads from
    /// the copy itself — "Press ▶" through "Press ■" — and does not need a
    /// line drawn between them.
    private func welcomeStep(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Circle()
                .fill(Self.axoMint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
                .fixedSize()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .frame(maxWidth: 340, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// One greeting wave when Axo first appears on a still-idle app. The mood
    /// returns to idle after the beat, but only if neither the user nor the
    /// session lifecycle has claimed it in the meantime. Skipped entirely when
    /// the system is reducing motion.
    private func greetOnArrival() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        guard model.sessionState == .idle, MascotSession.shared.mood == .idle else { return }
        MascotSession.shared.setMood(.celebrate)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if model.sessionState == .idle, MascotSession.shared.mood == .celebrate {
                MascotSession.shared.setMood(.idle)
            }
        }
    }
}
