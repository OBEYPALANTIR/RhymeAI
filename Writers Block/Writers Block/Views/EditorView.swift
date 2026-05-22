import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

struct EditorView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var keyboardIsVisible = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var assistantSheetDragOffset: CGFloat = 0
    @State private var pendingExport: (format: ExportFormat, doc: ExportDocument)?
    @State private var fileExporterPresented: Bool = false
    @State private var projectDrawerOpen: Bool = false
    @State private var lyricsEditorIsFocused = false
    @State private var rewriteAccessoryHeight: CGFloat = 0

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .overlay {
            if projectDrawerOpen {
                ProjectsDrawerView(isPresented: $projectDrawerOpen)
            }
        }
        .onAppear {
            viewModel.modelContext = modelContext
        }
        .sheet(
            isPresented: $viewModel.showExportSheet,
            onDismiss: {
                if pendingExport != nil { fileExporterPresented = true }
            }
        ) {
            ExportSheet(
                onPick: { format in
                    let project = viewModel.snapshotForExport()
                    do {
                        let data = try LyricsExporter.data(for: project, format: format)
                        pendingExport = (format, ExportDocument(data: data))
                    } catch {
                        viewModel.errorMessage = "Export failed: \(error.localizedDescription)"
                        pendingExport = nil
                    }
                    viewModel.showExportSheet = false
                },
                onDismiss: { viewModel.showExportSheet = false }
            )
        }
        .fileExporter(
            isPresented: $fileExporterPresented,
            document: pendingExport?.doc,
            contentType: pendingExport?.format.contentType ?? .data,
            defaultFilename: pendingExport.map { suggestedFilename(format: $0.format) }
        ) { _ in
            pendingExport = nil
        }
    }

    private func suggestedFilename(format: ExportFormat) -> String {
        let raw = viewModel.title.isEmpty ? "Untitled" : viewModel.title
        let safe = raw.replacingOccurrences(of: "[^A-Za-z0-9_\\- ]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let base = safe.isEmpty ? "Untitled" : safe
        return base
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - iPad Layout (split view)

    private var iPadLayout: some View {
        HStack(spacing: 0) {
            // Editor column
            VStack(spacing: 0) {
                topBar
                editorScrollView
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                rewriteAccessoryBar
                    .padding(.horizontal, RhymeAITokens.Spacing.md)
                    .padding(.bottom, RhymeAITokens.Spacing.sm)
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Persistent assistant column
            AssistantPanelView(isInline: true)
                .frame(width: RhymeAITokens.Layout.assistantColumnWidth)
        }
    }

    // MARK: - iPhone Layout (FAB + sheet)

    private var iPhoneLayout: some View {
        ZStack(alignment: .bottom) {
            Color(UIColor.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                editorScrollView
            }
            .allowsHitTesting(!viewModel.showAssistantSheet)
            .accessibilityHidden(viewModel.showAssistantSheet)

            rewriteAccessoryBar
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .padding(.bottom, keyboardIsVisible ? keyboardHeight + RhymeAITokens.Spacing.xs : RhymeAITokens.Spacing.sm)
                .zIndex(1.5)

            assistantFloatingButton
                .zIndex(1)

            assistantSheetOverlay
                .zIndex(2)
        }
        .animation(RhymeAITokens.Motion.presentation, value: viewModel.showAssistantSheet)
        .animation(RhymeAITokens.Motion.state, value: keyboardIsVisible)
        .animation(RhymeAITokens.Motion.state, value: lyricsEditorIsFocused)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
            keyboardHeight = 0
        }
        .onChange(of: viewModel.showAssistantSheet) { _, isPresented in
            if isPresented {
                assistantSheetDragOffset = 0
            }
        }
        .simultaneousGesture(assistantBackSwipeGesture, including: viewModel.showAssistantSheet ? .all : .subviews)
    }

    @ViewBuilder
    private var assistantFloatingButton: some View {
        if !viewModel.showAssistantSheet && !keyboardIsVisible && !lyricsEditorIsFocused {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        presentAssistantSheet()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pencil")
                                .font(.body.weight(.semibold))
                            UnBlockWordmark()
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, RhymeAITokens.Spacing.md)
                        .padding(.vertical, RhymeAITokens.Spacing.sm)
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill, tint: .indigo, interactive: true, fallbackOpacity: 0.35)
                        .shadow(color: .indigo.opacity(0.26), radius: 12, y: 4)
                    }
                    .accessibilityIdentifier("unblockButton")
                    .padding(.trailing, RhymeAITokens.Spacing.md)
                    .padding(.bottom, RhymeAITokens.Spacing.md)
                }
            }
            .transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var assistantSheetOverlay: some View {
        GeometryReader { proxy in
            if viewModel.showAssistantSheet {
                VStack(spacing: 0) {
                    assistantSheetDragHandle(sheetHeight: proxy.size.height)
                        .padding(.top, proxy.safeAreaInsets.top + RhymeAITokens.Spacing.xs)

                    AssistantPanelView(onDismiss: dismissAssistantSheetWithAnimation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background(Color(UIColor.systemBackground))
                .offset(y: assistantSheetDragOffset)
                .transition(.move(edge: .bottom))
                .ignoresSafeArea()
            }
        }
    }

    private func assistantSheetDragHandle(sheetHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: RhymeAITokens.Layout.assistantSheetHandleArea)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: RhymeAITokens.Layout.assistantSheetHandleWidth, height: RhymeAITokens.Layout.assistantSheetHandleHeight)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .onChanged { value in
                        assistantSheetDragOffset = min(max(0, value.translation.height), sheetHeight)
                    }
                    .onEnded { value in
                        settleAssistantSheetDrag(
                            translation: value.translation.height,
                            predictedTranslation: value.predictedEndTranslation.height,
                            sheetHeight: sheetHeight
                        )
                    }
            )
            .accessibilityLabel("Dismiss Assistant")
            .accessibilityIdentifier("assistantSheetGrabber")
    }

    private func settleAssistantSheetDrag(
        translation: CGFloat,
        predictedTranslation: CGFloat,
        sheetHeight: CGFloat
    ) {
        let dragDistance = max(0, translation)
        let projectedDistance = max(0, predictedTranslation)
        let closeThreshold = min(180, max(96, sheetHeight * 0.18))

        if dragDistance >= closeThreshold || projectedDistance >= closeThreshold {
            withAnimation(RhymeAITokens.Motion.dismiss) {
                assistantSheetDragOffset = sheetHeight
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + RhymeAITokens.Motion.feedbackDuration) {
                viewModel.showAssistantSheet = false
                assistantSheetDragOffset = 0
            }
        } else {
            withAnimation(RhymeAITokens.Motion.settle) {
                assistantSheetDragOffset = 0
            }
        }
    }

    private func presentAssistantSheet() {
        dismissKeyboard()

        if keyboardIsVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + RhymeAITokens.Motion.stateDuration) {
                showAssistantSheetWithAnimation()
            }
        } else {
            showAssistantSheetWithAnimation()
        }
    }

    private func showAssistantSheetWithAnimation() {
        assistantSheetDragOffset = 0
        withAnimation(RhymeAITokens.Motion.presentation) {
            viewModel.showAssistantSheet = true
        }
    }

    private var assistantBackSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 18, coordinateSpace: .local)
            .onEnded { value in
                guard viewModel.showAssistantSheet else { return }
                guard value.startLocation.x <= 32 else { return }
                guard value.translation.width > 60 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                dismissAssistantSheetWithAnimation()
            }
    }

    private func dismissAssistantSheetWithAnimation() {
        assistantSheetDragOffset = 0
        withAnimation(RhymeAITokens.Motion.dismiss) {
            viewModel.showAssistantSheet = false
        }
    }

    // MARK: - Shared Editor Content

    @ViewBuilder
    private var rewriteAccessoryBar: some View {
        Group {
            if !viewModel.showAssistantSheet {
                if let action = viewModel.rewriteAction {
                    InlineRewriteReviewBar(
                        action: action,
                        loading: viewModel.rewriteLoading,
                        preview: viewModel.rewritePreview,
                        error: viewModel.rewriteError,
                        onApply: { viewModel.applyRewrite() },
                        onCancel: { viewModel.dismissRewrite() },
                        onRetry: { viewModel.retryRewrite() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if shouldShowRewriteChipBar {
                    RewriteChipBar { action in
                        viewModel.requestRewrite(action)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(RhymeAITokens.Motion.state, value: shouldShowRewriteChipBar)
        .animation(RhymeAITokens.Motion.state, value: viewModel.hasActiveRewrite)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: RewriteAccessoryHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .onPreferenceChange(RewriteAccessoryHeightPreferenceKey.self) { height in
            rewriteAccessoryHeight = height
        }
    }

    private var shouldShowRewriteChipBar: Bool {
        (viewModel.selectedRange.length > 0 || forceRewriteChipBarForUITests)
            && viewModel.rewriteAction == nil
            && !viewModel.showAssistantSheet
    }

    private var forceRewriteChipBarForUITests: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-force-rewrite-bar")
    }

    private var editorScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Title Field
                TextField("Song Title...", text: $viewModel.title)
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .padding(.horizontal, RhymeAITokens.Spacing.md)
                    .padding(.top, RhymeAITokens.Spacing.md)
                    .padding(.bottom, RhymeAITokens.Spacing.sm)
                    .accessibilityIdentifier("songTitleEditor")
                    .onChange(of: viewModel.title) {
                        viewModel.triggerAutoSave()
                    }

                // Lyrics Editor
                ZStack(alignment: .topLeading) {
                    // Coloring overlay
                    if overlayActive && !viewModel.hasActiveRewrite && !viewModel.lyrics.isEmpty {
                        RhymeHighlightedText(
                            text: viewModel.lyrics,
                            enabled: viewModel.isRhymeHighlightEnabled,
                            syllablesEnabled: viewModel.isSyllableColoringEnabled
                        )
                        .equatable()
                        .padding(.horizontal, RhymeAITokens.Spacing.md)
                    }

                    // Actual text view
                    LyricsTextView(
                        text: $viewModel.lyrics,
                        displayText: viewModel.hasActiveRewrite ? viewModel.inlineRewriteText : nil,
                        rewriteHighlight: inlineRewriteHighlight,
                        onCursorChange: { pos in
                            if !viewModel.hasActiveRewrite {
                                viewModel.cursorPosition = pos
                            }
                        },
                        onSelectionChange: { range in
                            if !viewModel.hasActiveRewrite {
                                viewModel.selectedRange = range
                            }
                        },
                        onEditingChange: { isEditing in
                            lyricsEditorIsFocused = isEditing
                        },
                        bottomOverlayHeight: selectionAvoidanceInset,
                        isTransparentText: overlayActive && !viewModel.hasActiveRewrite && !viewModel.lyrics.isEmpty,
                        isEditable: !viewModel.hasActiveRewrite
                    )
                    .frame(minHeight: 400)
                    .padding(.horizontal, RhymeAITokens.Spacing.md)
                    .onChange(of: viewModel.lyrics) {
                        viewModel.triggerAutoSave()
                    }
                }

                Spacer(minLength: RhymeAITokens.Layout.editorBottomRest)
            }
            .frame(maxWidth: RhymeAITokens.Layout.editorMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(UIColor.systemBackground))
    }

    private var selectionAvoidanceInset: CGFloat {
        guard shouldShowRewriteChipBar || viewModel.hasActiveRewrite else { return 0 }
        return rewriteAccessoryHeight + RhymeAITokens.Spacing.md
    }

    private var overlayActive: Bool {
        viewModel.isRhymeHighlightEnabled || viewModel.isSyllableColoringEnabled
    }

    private var inlineRewriteHighlight: LyricsRewriteHighlight? {
        guard let range = viewModel.inlineRewriteRange else { return nil }
        return LyricsRewriteHighlight(
            range: range,
            isLoading: viewModel.rewriteLoading,
            isError: viewModel.rewriteError != nil
        )
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                projectDrawerOpen = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Open songs drawer")

            // Save status
            if viewModel.saveStatus == .saving {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Saving...")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            } else if viewModel.saveStatus == .saved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.caption)
                    Text("Saved")
                        .font(.caption)
                }
                .foregroundStyle(.green.opacity(0.8))
            }

            Spacer()

            // Word & Syllable counts
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(viewModel.wordCount) words")
                    .font(.caption2)
                Text("\(viewModel.syllableCount) syllables")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)

            // Export
            Button {
                dismissKeyboard()
                viewModel.showExportSheet = true
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.body)
                    .foregroundStyle(Color.secondary.opacity(viewModel.lyrics.isEmpty ? 0.4 : 1.0))
                    .frame(width: 44, height: 44)
            }
            .disabled(viewModel.lyrics.isEmpty)

            // Settings
            Button {
                dismissKeyboard()
                viewModel.showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.xs)
        .padding(.vertical, RhymeAITokens.Spacing.xs)
        .liquidGlassSurface(cornerRadius: 0, fallbackOpacity: 0.02)
        .overlay(
            Divider(), alignment: .bottom
        )
    }
}

private struct RewriteAccessoryHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InlineRewriteReviewBar: View {
    let action: RewriteAction
    let loading: Bool
    let preview: String?
    let error: String?
    var onApply: () -> Void
    var onCancel: () -> Void
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                if loading {
                    ProgressView()
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: error == nil ? "sparkles" : "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                }

                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(error == nil ? .indigo : .red)
            .frame(maxWidth: .infinity, alignment: .leading)

            if error != nil {
                Button("Retry", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .frame(minWidth: 72, minHeight: RhymeAITokens.Touch.minimum)
                    .buttonStyle(.rhymePress)
            } else if preview != nil {
                Button("Apply", action: onApply)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 72, minHeight: RhymeAITokens.Touch.minimum)
                    .background(.indigo, in: Capsule())
                    .buttonStyle(.rhymePress)
            }

            Button("Cancel", action: onCancel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 72, minHeight: RhymeAITokens.Touch.minimum)
                .buttonStyle(.rhymePress)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .padding(.vertical, RhymeAITokens.Spacing.xs)
        .frame(maxWidth: RhymeAITokens.Layout.drawerMaxWidth)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill, tint: .indigo.opacity(0.08), fallbackOpacity: 0.85)
        .liquidGlassGroup(spacing: RhymeAITokens.Spacing.sm)
        .accessibilityIdentifier("inlineRewriteReviewBar")
    }

    private var statusText: String {
        if let error, !error.isEmpty {
            return error
        }
        if loading {
            return "\(action.label)..."
        }
        if preview != nil {
            return "Previewing \(action.label)"
        }
        return action.label
    }
}

private struct UnBlockWordmark: View {
    var body: some View {
        VStack(spacing: 1) {
            Text("UnBlock")
                .font(.body.weight(.semibold))

            ScribbleUnderline()
                .frame(width: 58, height: 5)
        }
    }
}

private struct ScribbleUnderline: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height * 0.55))
            path.addLine(to: CGPoint(x: size.width * 0.18, y: size.height * 0.25))
            path.addLine(to: CGPoint(x: size.width * 0.42, y: size.height * 0.78))
            path.addLine(to: CGPoint(x: size.width * 0.68, y: size.height * 0.28))
            path.addLine(to: CGPoint(x: size.width, y: size.height * 0.58))

            context.stroke(
                path,
                with: .color(.white.opacity(0.9)),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
            )
        }
    }
}

#Preview {
    EditorView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self], inMemory: true)
}
