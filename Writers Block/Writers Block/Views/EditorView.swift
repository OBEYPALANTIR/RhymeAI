import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

func compactEditorStatsText(wordCount: Int, syllableCount: Int) -> String {
    "\(wordCount)w · \(syllableCount)s"
}

private enum EditorViewConstants {
    enum UnBlockChrome {
        static let expandedButtonWidth: CGFloat = 136
        static let expandedWordmarkWidth: CGFloat = 76
        static let collapsedWordmarkWidth: CGFloat = 0
        static let visibleWordmarkOpacity: Double = 1
        static let hiddenWordmarkOpacity: Double = 0
        static let transitionScale: CGFloat = 0.92
        static let surfaceFallbackOpacity: Double = 0.35
        static let shadowOpacity: Double = 0.26
    }

    enum AssistantSheet {
        static let dragMinimumDistance: CGFloat = 8
        static let closeThresholdMinimum: CGFloat = 96
        static let closeThresholdMaximum: CGFloat = 180
        static let closeThresholdHeightRatio: CGFloat = 0.18
        static let backSwipeMinimumDistance: CGFloat = 18
        static let backSwipeStartX: CGFloat = 32
        static let backSwipeTranslation: CGFloat = 60
        static let restingOffset: CGFloat = 0
        static let grabberOpacity: Double = 0.45
    }

    enum EditorLayout {
        static let lyricsMinimumHeight: CGFloat = 400
        static let stackSpacing: CGFloat = 0
        static let accessoryZIndex: Double = 1.5
        static let floatingButtonZIndex: Double = 1
        static let assistantSheetZIndex: Double = 2
        static let noAccessoryHeight: CGFloat = 0
        static let noSelectionAvoidanceInset: CGFloat = 0
    }

    enum Keyboard {
        static let hiddenHeight: CGFloat = 0
    }

    enum TopBar {
        static let saveProgressScale: CGFloat = 0.6
        static let savedStatusOpacity: Double = 0.8
        static let disabledExportOpacity: Double = 0.4
        static let enabledExportOpacity: Double = 1.0
    }

    enum ControlChrome {
        static let iconSize: CGFloat = 17
    }

    enum RewriteReview {
        static let progressScale: CGFloat = 0.72
        static let statusMinimumScale: CGFloat = 0.82
        static let actionButtonMinWidth: CGFloat = 72
        static let surfaceTintOpacity: Double = 0.08
        static let surfaceFallbackOpacity: Double = 0.85
        static let statusLineLimit = 1
    }

    enum Wordmark {
        static let verticalSpacing: CGFloat = 1
        static let underlineWidth: CGFloat = 58
        static let underlineHeight: CGFloat = 5
    }

    enum Scribble {
        static let start = CGPoint(x: 0, y: 0.55)
        static let firstPeak = CGPoint(x: 0.18, y: 0.25)
        static let centerDip = CGPoint(x: 0.42, y: 0.78)
        static let secondPeak = CGPoint(x: 0.68, y: 0.28)
        static let end = CGPoint(x: 1, y: 0.58)
        static let strokeOpacity: Double = 0.9
        static let strokeWidth: CGFloat = 1.6

        static func point(_ unitPoint: CGPoint, in size: CGSize) -> CGPoint {
            CGPoint(x: size.width * unitPoint.x, y: size.height * unitPoint.y)
        }
    }
}

struct EditorView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAppearanceStyle) private var appearance
    @State private var writingScrollPosition = ScrollPosition(y: 0)
    @State private var restoringScroll = false
    @State private var keyboardIsVisible = false
    @State private var keyboardHeight: CGFloat = EditorViewConstants.Keyboard.hiddenHeight
    @State private var assistantSheetDragOffset: CGFloat = EditorViewConstants.AssistantSheet.restingOffset
    @State private var assistantSheetIsDismissing = false
    @State private var assistantSheetLifecycleTask: Task<Void, Never>?
    @State private var recordingSong: RecordingSong?
    private struct RecordingSong: Identifiable {
        let id: String
        let title: String
    }

    @State private var pendingExport: (format: ExportFormat, doc: ExportDocument)?
    @State private var fileExporterPresented: Bool = false
    @State private var projectDrawerOpen: Bool = false
    @State private var lyricsEditorIsFocused = false
    @State private var rewriteAccessoryHeight: CGFloat = EditorViewConstants.EditorLayout.noAccessoryHeight
    // UnBlock collapses into a pencil circle while the mic is recording.
    @State private var unblockWordmarkOpacity: Double = EditorViewConstants.UnBlockChrome.visibleWordmarkOpacity
    @State private var unblockButtonWidth: CGFloat = EditorViewConstants.UnBlockChrome.expandedButtonWidth
    @State private var unblockWordmarkWidth: CGFloat = EditorViewConstants.UnBlockChrome.expandedWordmarkWidth
    @State private var unblockCollapsed: Bool = false
    @State private var inlineAssistantVisible = true
    @State private var isFocusMode = false

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .foregroundStyle(appearance.palette.primaryInk)
        .background {
            AppWritingBackground()
        }
        .overlay {
            if projectDrawerOpen {
                ProjectsDrawerView(isPresented: $projectDrawerOpen)
            }
        }
        .onAppear {
            viewModel.modelContext = modelContext
            if viewModel.showAssistantSheet {
                assistantSheetDragOffset = EditorViewConstants.AssistantSheet.restingOffset
            }
        }
        .task(id: viewModel.insertionFeedbackID) {
            guard viewModel.insertionFeedbackID != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            viewModel.clearInsertionHighlight()
            try? await Task.sleep(for: .seconds(UIAccessibility.isVoiceOverRunning ? 28 : 6))
            guard !Task.isCancelled else { return }
            viewModel.clearInsertionFeedback()
        }
        .onChange(of: viewModel.voiceMemoService.isRecording) { _, isRecording in
            withAnimation(reduceMotion ? nil : RhymeAITokens.Motion.recording) {
                unblockWordmarkOpacity = isRecording ? EditorViewConstants.UnBlockChrome.hiddenWordmarkOpacity : EditorViewConstants.UnBlockChrome.visibleWordmarkOpacity
                unblockButtonWidth = isRecording ? RhymeAITokens.Touch.comfortable : EditorViewConstants.UnBlockChrome.expandedButtonWidth
                unblockWordmarkWidth = isRecording ? EditorViewConstants.UnBlockChrome.collapsedWordmarkWidth : EditorViewConstants.UnBlockChrome.expandedWordmarkWidth
                unblockCollapsed = isRecording
            }
        }
        .alert(item: $viewModel.cloudAISharingRequest) { request in
            Alert(
                title: Text("Share with \(request.provider.displayName)?"),
                message: Text("Before continuing, review the sharing details. \(viewModel.cloudAISharingDisclosure) You can revoke permission in Settings."),
                primaryButton: .default(Text("Allow and Continue")) {
                    viewModel.approveCloudAISharing(request)
                },
                secondaryButton: .cancel {
                    viewModel.cancelCloudAISharing()
                }
            )
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
        .sheet(isPresented: $viewModel.showNotebook) {
            SongNotebookView()
        }
        .sheet(item: $recordingSong) { song in
            SongRecordingsView(projectId: song.id, projectTitle: song.title)
        }
        .fileExporter(
            isPresented: $fileExporterPresented,
            document: pendingExport?.doc,
            contentType: pendingExport?.format.contentType ?? .data,
            defaultFilename: pendingExport.map { suggestedFilename(format: $0.format) }
        ) { result in
            if case .failure(let error) = result {
                viewModel.errorMessage = "Export failed: \(error.localizedDescription)"
            }
            pendingExport = nil
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.showInspector },
                set: { newValue in if !newValue { viewModel.dismissInspector() } }
            ),
            onDismiss: { viewModel.inspectorDidDismiss() }
        ) {
            if let word = viewModel.inspectorWord {
                if #available(iOS 16.0, *) {
                    WordInspectorSheetView(
                        word: word,
                        prosody: viewModel.inspectorProsody,
                        matches: viewModel.inspectorMatches,
                        synonyms: viewModel.inspectorSynonyms,
                        synonymsLoading: viewModel.inspectorSynonymsLoading,
                        synonymsError: viewModel.inspectorSynonymsError,
                        synonymsRecovery: viewModel.inspectorSynonymsRecovery,
                        onReplace: { viewModel.applyInspectorReplacement($0) },
                        onRetrySynonyms: { viewModel.retryInspectorSynonyms() },
                        onOpenSettings: { viewModel.openSettingsFromInspector() },
                        onDismiss: { viewModel.dismissInspector() }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                } else {
                    WordInspectorSheetView(
                        word: word,
                        prosody: viewModel.inspectorProsody,
                        matches: viewModel.inspectorMatches,
                        synonyms: viewModel.inspectorSynonyms,
                        synonymsLoading: viewModel.inspectorSynonymsLoading,
                        synonymsError: viewModel.inspectorSynonymsError,
                        synonymsRecovery: viewModel.inspectorSynonymsRecovery,
                        onReplace: { viewModel.applyInspectorReplacement($0) },
                        onRetrySynonyms: { viewModel.retryInspectorSynonyms() },
                        onOpenSettings: { viewModel.openSettingsFromInspector() },
                        onDismiss: { viewModel.dismissInspector() }
                    )
                }
            }
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
        HStack(spacing: EditorViewConstants.EditorLayout.stackSpacing) {
            // Editor column
            ZStack(alignment: .bottom) {
                VStack(spacing: EditorViewConstants.EditorLayout.stackSpacing) {
                    topBar
                    editorScrollView
                        .padding(.bottom, iPadEditorBottomClearance)
                }
                .safeAreaInset(edge: .bottom, spacing: EditorViewConstants.EditorLayout.stackSpacing) {
                    rewriteAccessoryBar
                        .padding(.horizontal, RhymeAITokens.Spacing.md)
                        .padding(.bottom, RhymeAITokens.Spacing.sm)
                }

                iPadEditorActions
                    .zIndex(EditorViewConstants.EditorLayout.floatingButtonZIndex)
            }
            .frame(maxWidth: .infinity)

            if inlineAssistantVisible && !isFocusMode {
                Divider()

                AssistantPanelView(
                    isInline: true,
                    onDismiss: hideInlineAssistant
                )
                .frame(width: RhymeAITokens.Layout.assistantColumnWidth)
                .transition(.opacity)
            }
        }
        .rhymeAnimation(RhymeAITokens.Motion.presentation, value: inlineAssistantVisible)
        .rhymeAnimation(RhymeAITokens.Motion.state, value: editorActionsVisible)
    }

    // MARK: - iPhone Layout (FAB + sheet)

    private var iPhoneLayout: some View {
        ZStack(alignment: .bottom) {
            AppWritingBackground()

            VStack(spacing: EditorViewConstants.EditorLayout.stackSpacing) {
                topBar
                editorScrollView
                    .padding(.bottom, iPhoneEditorBottomClearance)
            }
            .allowsHitTesting(!assistantSheetIsActive)
            .accessibilityHidden(assistantSheetIsActive)

            rewriteAccessoryBar
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .padding(.bottom, keyboardIsVisible ? keyboardHeight + RhymeAITokens.Spacing.xs : RhymeAITokens.Spacing.sm)
                .zIndex(EditorViewConstants.EditorLayout.accessoryZIndex)

            assistantFloatingButton
                .zIndex(EditorViewConstants.EditorLayout.floatingButtonZIndex)

            assistantSheetOverlay
                .zIndex(EditorViewConstants.EditorLayout.assistantSheetZIndex)
        }
        .rhymeAnimation(assistantSheetTransitionAnimation, value: viewModel.showAssistantSheet)
        .rhymeAnimation(RhymeAITokens.Motion.state, value: editorActionsVisible)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardHeight = frame.height
            }
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
            keyboardHeight = EditorViewConstants.Keyboard.hiddenHeight
        }
        .onChange(of: viewModel.showAssistantSheet) { _, isPresented in
            if isPresented {
                assistantSheetLifecycleTask?.cancel()
                assistantSheetIsDismissing = false
                assistantSheetDragOffset = EditorViewConstants.AssistantSheet.restingOffset
            } else if !assistantSheetIsDismissing {
                holdAssistantDismissalGate()
            }
        }
        .simultaneousGesture(assistantBackSwipeGesture, including: assistantSheetIsActive ? .all : .subviews)
    }

    private var assistantModalOpen: Bool {
        viewModel.showSettingsSheet || viewModel.showExportSheet || projectDrawerOpen
    }

    private var assistantSheetIsActive: Bool {
        guard horizontalSizeClass != .regular else { return false }
        return viewModel.showAssistantSheet || assistantSheetIsDismissing
    }

    private var assistantSheetTransitionAnimation: Animation {
        viewModel.showAssistantSheet ? RhymeAITokens.Motion.presentation : RhymeAITokens.Motion.dismiss
    }

    private var editorActionsVisible: Bool {
        !isFocusMode && viewModel.insertionFeedbackID == nil && !assistantSheetIsActive &&
            !assistantModalOpen &&
            !viewModel.hasActiveRewrite &&
            !shouldShowRewriteChipBar
    }

    private var historyControlsVisible: Bool {
        !assistantSheetIsActive && !assistantModalOpen && !viewModel.hasActiveRewrite
            && !shouldShowRewriteChipBar && !viewModel.voiceMemoService.isRecording
    }

    private var usesCompactControlChrome: Bool {
        horizontalSizeClass == .compact && dynamicTypeSize.isAccessibilitySize
    }

    @ViewBuilder
    private var iPadEditorActions: some View {
        if editorActionsVisible {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    editorActionCluster
                }
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .padding(.bottom, RhymeAITokens.Spacing.md)
            }
            .transition(reduceMotion ? .opacity : .scale(scale: EditorViewConstants.UnBlockChrome.transitionScale, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var assistantFloatingButton: some View {
        // Hidden when the assistant sheet is up, a modal is up, or an inline
        // rewrite is being reviewed. It also yields to the selection rewrite
        // bar: on iPhone both are anchored to the bottom, so the FAB would
        // otherwise show through behind the chip bar. (Android keeps its FAB up
        // during selection because its bottom-end FAB and centered chip bar do
        // not overlap.) Keyboard does NOT hide the button — it rides above it.
        // The mic button shares this exact condition so both appear/disappear together.
        if editorActionsVisible {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    editorActionCluster
                }
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .padding(.bottom, keyboardIsVisible
                         ? keyboardHeight + RhymeAITokens.Spacing.sm
                         : RhymeAITokens.Spacing.md)
            }
            .transition(reduceMotion ? .opacity : .scale(scale: EditorViewConstants.UnBlockChrome.transitionScale, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    private var iPadEditorBottomClearance: CGFloat {
        guard editorActionsVisible else { return 0 }
        let actionHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 96 : RhymeAITokens.Touch.comfortable
        return actionHeight + RhymeAITokens.Spacing.md + RhymeAITokens.Spacing.sm
    }

    private var iPhoneEditorBottomClearance: CGFloat {
        let keyboardClearance = keyboardIsVisible ? keyboardHeight : 0
        guard editorActionsVisible else { return keyboardClearance }
        let actionBottomSpacing = keyboardIsVisible ? RhymeAITokens.Spacing.sm : RhymeAITokens.Spacing.md
        return keyboardClearance + actionBottomSpacing
            + RhymeAITokens.Touch.comfortable + RhymeAITokens.Spacing.sm
    }

    private var editorActionCluster: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            Button {
                presentAssistant()
            } label: {
                HStack(spacing: unblockCollapsed || usesCompactControlChrome ? EditorViewConstants.UnBlockChrome.collapsedWordmarkWidth : RhymeAITokens.Spacing.xs) {
                    Image(systemName: inlineAssistantIsOpen ? "sidebar.right" : "pencil")
                        .font(.system(size: EditorViewConstants.ControlChrome.iconSize, weight: .semibold))
                    if inlineAssistantIsOpen && !unblockCollapsed && !usesCompactControlChrome {
                        Text("Hide AI")
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: true, vertical: true)
                    } else if !usesCompactControlChrome {
                        UnBlockWordmark()
                            .fixedSize(horizontal: true, vertical: true)
                            .opacity(unblockWordmarkOpacity)
                            .frame(width: horizontalSizeClass == .regular && dynamicTypeSize.isAccessibilitySize && !unblockCollapsed ? nil : unblockWordmarkWidth)
                            .clipped()
                    }
                }
                .foregroundStyle(appearance.palette.onAction)
                .padding(.vertical, RhymeAITokens.Spacing.sm)
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .frame(
                    minWidth: usesCompactControlChrome ? RhymeAITokens.Touch.comfortable : unblockButtonWidth,
                    minHeight: RhymeAITokens.Touch.comfortable
                )
                .appearanceActionSurface(cornerRadius: RhymeAITokens.Radius.pill)
                .shadow(color: appearance.palette.primaryInk.opacity(EditorViewConstants.UnBlockChrome.shadowOpacity), radius: RhymeAITokens.Spacing.sm, y: RhymeAITokens.Spacing.xxs)
            }
            .buttonStyle(.rhymePress)
            .accessibilityLabel(inlineAssistantVisible && horizontalSizeClass == .regular ? "Hide AI suggestions" : "Open AI suggestions")
            .accessibilityIdentifier("unblockButton")

            FloatingMicButton(
                service: viewModel.voiceMemoService,
                ensureProjectId: { viewModel.ensureProjectForRecording() }
            )
        }
        .dynamicTypeSize(usesCompactControlChrome ? .large : dynamicTypeSize)
    }

    private var inlineAssistantIsOpen: Bool {
        inlineAssistantVisible && horizontalSizeClass == .regular && !isFocusMode
    }

    @ViewBuilder
    private var assistantSheetOverlay: some View {
        GeometryReader { proxy in
            if viewModel.showAssistantSheet {
                VStack(spacing: EditorViewConstants.EditorLayout.stackSpacing) {
                    assistantSheetDragHandle(sheetHeight: proxy.size.height)
                        .padding(.top, proxy.safeAreaInsets.top + RhymeAITokens.Spacing.xs)

                    AssistantPanelView(onDismiss: dismissAssistantSheetWithAnimation)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background(appearance.palette.canvas)
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
                    .fill(.secondary.opacity(EditorViewConstants.AssistantSheet.grabberOpacity))
                    .frame(width: RhymeAITokens.Layout.assistantSheetHandleWidth, height: RhymeAITokens.Layout.assistantSheetHandleHeight)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: EditorViewConstants.AssistantSheet.dragMinimumDistance, coordinateSpace: .local)
                    .onChanged { value in
                        assistantSheetDragOffset = min(max(EditorViewConstants.AssistantSheet.restingOffset, value.translation.height), sheetHeight)
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
        let dragDistance = max(EditorViewConstants.AssistantSheet.restingOffset, translation)
        let projectedDistance = max(EditorViewConstants.AssistantSheet.restingOffset, predictedTranslation)
        // Gesture threshold — tuned by feel, not derived from the φ scale.
        let closeThreshold = min(EditorViewConstants.AssistantSheet.closeThresholdMaximum, max(EditorViewConstants.AssistantSheet.closeThresholdMinimum, sheetHeight * EditorViewConstants.AssistantSheet.closeThresholdHeightRatio))

        if dragDistance >= closeThreshold || projectedDistance >= closeThreshold {
            dismissAssistantSheetWithAnimation()
        } else {
            withRhymeAnimation(RhymeAITokens.Motion.settle, reduceMotion: reduceMotion) {
                assistantSheetDragOffset = EditorViewConstants.AssistantSheet.restingOffset
            }
        }
    }

    private var assistantBackSwipeGesture: some Gesture {
        // Gesture thresholds — tuned for back-swipe feel, intentionally off the φ scale.
        DragGesture(minimumDistance: EditorViewConstants.AssistantSheet.backSwipeMinimumDistance, coordinateSpace: .local)
            .onEnded { value in
                guard assistantSheetIsActive else { return }
                guard value.startLocation.x <= EditorViewConstants.AssistantSheet.backSwipeStartX else { return }
                guard value.translation.width > EditorViewConstants.AssistantSheet.backSwipeTranslation else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                dismissAssistantSheetWithAnimation()
            }
    }

    private func presentAssistantSheet() {
        dismissKeyboard()
        assistantSheetLifecycleTask?.cancel()

        if keyboardIsVisible {
            assistantSheetLifecycleTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(RhymeAITokens.Motion.stateDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                showAssistantSheetWithAnimation()
            }
        } else {
            showAssistantSheetWithAnimation()
        }
    }

    private func presentAssistant() {
        if horizontalSizeClass == .regular {
            withRhymeAnimation(RhymeAITokens.Motion.presentation, reduceMotion: reduceMotion) {
                inlineAssistantVisible.toggle()
            }
        } else {
            presentAssistantSheet()
        }
    }

    private func hideInlineAssistant() {
        withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
            inlineAssistantVisible = false
        }
    }

    private func showAssistantSheetWithAnimation() {
        assistantSheetLifecycleTask?.cancel()
        assistantSheetIsDismissing = false
        assistantSheetDragOffset = EditorViewConstants.AssistantSheet.restingOffset
        withRhymeAnimation(RhymeAITokens.Motion.presentation, reduceMotion: reduceMotion) {
            viewModel.showAssistantSheet = true
        }
    }

    private func dismissAssistantSheetWithAnimation() {
        guard viewModel.showAssistantSheet || assistantSheetIsDismissing else { return }
        assistantSheetLifecycleTask?.cancel()
        assistantSheetIsDismissing = true
        withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
            viewModel.showAssistantSheet = false
        }
        scheduleAssistantDismissalGateRelease()
    }

    private func holdAssistantDismissalGate() {
        assistantSheetLifecycleTask?.cancel()
        assistantSheetIsDismissing = true
        scheduleAssistantDismissalGateRelease()
    }

    private func scheduleAssistantDismissalGateRelease() {
        if reduceMotion {
            assistantSheetIsDismissing = false
            assistantSheetDragOffset = EditorViewConstants.AssistantSheet.restingOffset
            return
        }

        assistantSheetLifecycleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(RhymeAITokens.Motion.feedbackDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            assistantSheetIsDismissing = false
            assistantSheetDragOffset = EditorViewConstants.AssistantSheet.restingOffset
        }
    }

    // MARK: - Shared Editor Content

    @ViewBuilder
    private var rewriteAccessoryBar: some View {
        Group {
            if !assistantSheetIsActive {
                if viewModel.insertionFeedbackID != nil {
                    HStack(spacing: RhymeAITokens.Spacing.md) {
                        Label("Line added", systemImage: "checkmark")
                            .font(.subheadline)
                            .accessibilityIdentifier("lineAddedFeedback")
                        Spacer(minLength: RhymeAITokens.Spacing.xs)
                        Button("Undo", action: viewModel.undoInsertedLine)
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                            .accessibilityIdentifier("undoInsertedLineButton")
                        if viewModel.voiceMemoService.isRecording {
                            Button("Stop", systemImage: "stop.fill") {
                                viewModel.voiceMemoService.stopRecording()
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                            .accessibilityLabel("Stop recording")
                        }
                    }
                    .padding(.horizontal, RhymeAITokens.Spacing.md)
                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md)
                    .transition(.opacity)
                } else if let action = viewModel.rewriteAction {
                    InlineRewriteReviewBar(
                        action: action,
                        loading: viewModel.rewriteLoading,
                        preview: viewModel.rewritePreview,
                        error: viewModel.rewriteError,
                        onApply: { viewModel.applyRewrite() },
                        onCancel: { viewModel.dismissRewrite() },
                        onRetry: { viewModel.retryRewrite() }
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                } else if shouldShowRewriteChipBar {
                    RewriteChipBar(
                        onAction: { viewModel.requestRewrite($0) },
                        onInspect: viewModel.singleWordSelection != nil
                            ? { viewModel.openInspectorForSelection() }
                            : nil
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .rhymeAnimation(RhymeAITokens.Motion.state, value: shouldShowRewriteChipBar)
        .rhymeAnimation(RhymeAITokens.Motion.state, value: viewModel.hasActiveRewrite)
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
        !isFocusMode && (viewModel.selectedRange.length > 0 || forceRewriteChipBarForUITests)
            && viewModel.rewriteAction == nil
            && !viewModel.showInspector
            && !assistantSheetIsActive
    }

    private var forceRewriteChipBarForUITests: Bool {
        UITestFlags.isEnabled(UITestFlags.forceRewriteBar)
    }

    private var editorScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: EditorViewConstants.EditorLayout.stackSpacing) {
                // Title Field
                TextField("Song Title...", text: $viewModel.title)
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, RhymeAITokens.Spacing.md)
                    .padding(.top, RhymeAITokens.Spacing.md)
                    .padding(.bottom, RhymeAITokens.Spacing.xxs)
                    .accessibilityIdentifier("songTitleEditor")
                    .onChange(of: viewModel.title) {
                        viewModel.triggerAutoSave()
                    }


                editorStats

                lyricsEditorInput

                Spacer(minLength: RhymeAITokens.Layout.editorBottomRest)
            }
            .frame(maxWidth: RhymeAITokens.Layout.editorMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($writingScrollPosition)
        .onScrollGeometryChange(for: Double.self) { geometry in
            Double(geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, y in
            if !restoringScroll { viewModel.updateEditorScroll(y) }
        }
        .task(id: viewModel.positionRestoreID) {
            restoringScroll = true
            let target = viewModel.companion.position.scrollY
            await Task.yield()
            writingScrollPosition.scrollTo(y: target)
            await Task.yield()
            restoringScroll = false
        }
        .scrollDismissesKeyboard(.immediately)
        .clipped()
        .accessibilityIdentifier("lyricsScrollView")
        .background(Color.clear)
    }

    private var editorStats: some View {
        (
            Text("\(viewModel.wordCount)w")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(hex: appearance.editorWordCountHexValue))
            + Text(" · ")
                .font(.caption)
                .foregroundColor(appearance.palette.secondaryInk)
            + Text("\(viewModel.syllableCount)s")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(hex: appearance.editorSyllableCountHexValue))
        )
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.bottom, RhymeAITokens.Spacing.md)
        .accessibilityIdentifier("editorStats")
        .opacity(isFocusMode ? 0 : 1)
        .accessibilityHidden(isFocusMode)
    }

    private var lyricsEditorInput: some View {
        LyricsTextView(
            text: Binding(
                get: { viewModel.lyrics },
                set: { viewModel.onLyricsChanged($0) }
            ),
            selection: viewModel.selectedRange,
            displayText: viewModel.hasActiveRewrite ? viewModel.inlineRewriteText : nil,
            rewriteHighlight: inlineRewriteHighlight,
            insertionHighlight: viewModel.insertedLineRange,
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
            rhymeHighlightEnabled: overlayActive && !viewModel.hasActiveRewrite && viewModel.isRhymeHighlightEnabled,
            syllableColoringEnabled: overlayActive && !viewModel.hasActiveRewrite && viewModel.isSyllableColoringEnabled,
            isEditable: !viewModel.hasActiveRewrite
        )
        .frame(minHeight: EditorViewConstants.EditorLayout.lyricsMinimumHeight)
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .onChange(of: viewModel.lyrics) {
            viewModel.triggerAutoSave()
        }
    }

    private var selectionAvoidanceInset: CGFloat {
        // Rewrite chip bar / active rewrite reserve their own bar height.
        if shouldShowRewriteChipBar || viewModel.hasActiveRewrite || viewModel.insertionFeedbackID != nil {
            return rewriteAccessoryHeight + RhymeAITokens.Spacing.md
        }
        return EditorViewConstants.EditorLayout.noSelectionAvoidanceInset
    }

    private var overlayActive: Bool {
        !isFocusMode && (viewModel.isRhymeHighlightEnabled || viewModel.isSyllableColoringEnabled)
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
        Group {
            if horizontalSizeClass == .regular && dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: RhymeAITokens.Spacing.xxs) {
                    HStack(spacing: RhymeAITokens.Spacing.xxs) {
                        topBarLeading
                        Spacer()
                    }
                    HStack(spacing: RhymeAITokens.Spacing.xxs) {
                        Spacer()
                        topBarTrailing
                    }
                }
            } else {
                HStack(spacing: RhymeAITokens.Spacing.xxs) {
                    topBarLeading
                    Spacer()
                    topBarTrailing
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, RhymeAITokens.Spacing.xs)
        .padding(.vertical, RhymeAITokens.Spacing.xs)
        .dynamicTypeSize(usesCompactControlChrome ? .large : dynamicTypeSize)
        .overlay(
            Divider(), alignment: .bottom
        )
    }

    private var topBarLeading: some View {
        HStack(spacing: RhymeAITokens.Spacing.xxs) {
            Button {
                projectDrawerOpen = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: EditorViewConstants.ControlChrome.iconSize))
                    .foregroundStyle(.secondary)
                    .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
            }
            .accessibilityLabel("Open songs drawer")

            if historyControlsVisible {
                EditorUndoRedoControls(
                    canUndo: viewModel.canUndoLyrics,
                    canRedo: viewModel.canRedoLyrics,
                    onUndo: viewModel.undoLyrics,
                    onRedo: viewModel.redoLyrics
                )
            }

            HStack(spacing: RhymeAITokens.Spacing.xs) {
                if viewModel.saveStatus == .saving {
                    ProgressView()
                        .scaleEffect(EditorViewConstants.TopBar.saveProgressScale)
                        .accessibilityLabel("Saving...")
                } else if viewModel.saveStatus == .failed {
                    Button {
                        viewModel.triggerAutoSave()
                    } label: {
                        Label("Save failed", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityLabel("Save failed. Retry saving")
                } else if viewModel.saveStatus == .saved {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(appearance.palette.success.opacity(EditorViewConstants.TopBar.savedStatusOpacity))
                        .accessibilityLabel("Saved")
                }
            }
            .rhymeAnimation(RhymeAITokens.Motion.feedback, value: viewModel.saveStatus)
        }
    }

    private var topBarTrailing: some View {
        HStack(spacing: RhymeAITokens.Spacing.xxs) {
            Button {
                withRhymeAnimation(nil, reduceMotion: reduceMotion) {
                    isFocusMode.toggle()
                }
            } label: {
                Group {
                    if usesCompactControlChrome {
                        Image(systemName: isFocusMode ? "arrow.down.right.and.arrow.up.left" : "viewfinder")
                            .font(.system(size: EditorViewConstants.ControlChrome.iconSize, weight: .medium))
                    } else {
                        ZStack {
                            Text("Exit Focus").hidden()
                            Text(isFocusMode ? "Exit Focus" : "Focus")
                        }
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                .contentShape(Rectangle())
            }
            .disabled(viewModel.hasActiveRewrite || viewModel.voiceMemoService.isRecording)
            .buttonStyle(.plain)
            .accessibilityLabel(isFocusMode ? "Exit Focus" : "Focus")
            .accessibilityValue(isFocusMode ? "On" : "Off")
            .accessibilityHint("Hides analysis and secondary controls while you write")
            .accessibilityIdentifier("focusModeButton")

            HStack(spacing: RhymeAITokens.Spacing.xxs) {
                if !isFocusMode {
                    Menu {
                        Menu("Insert section", systemImage: "plus") {
                            ForEach(SectionMap.standardLabels, id: \.self) { label in
                                Button(label) { viewModel.insertSection(label) }
                                    .accessibilityIdentifier("sectionMenu\(label.filter(\.isLetter))")
                            }
                        }
                        .disabled(viewModel.hasActiveRewrite)
                        .accessibilityIdentifier("sectionMenuButton")
                        Button("Song recordings", systemImage: "waveform") {
                            dismissKeyboard()
                            guard let id = viewModel.ensureProjectForRecording() else { return }
                            recordingSong = RecordingSong(id: id, title: viewModel.title.isEmpty ? "Untitled Song" : viewModel.title)
                        }
                        .accessibilityIdentifier("songRecordings")
                        Button("Song Notebook", systemImage: "book.closed") {
                            dismissKeyboard()
                            viewModel.showNotebook = true
                        }
                        if !viewModel.selectedLyrics.isEmpty {
                            Button("Keep selection", systemImage: "bookmark") {
                                viewModel.keepAlternate(viewModel.selectedLyrics)
                            }
                        }
                        Button("Export", systemImage: "square.and.arrow.up") {
                            dismissKeyboard()
                            viewModel.showExportSheet = true
                        }
                        .disabled(viewModel.lyrics.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: EditorViewConstants.ControlChrome.iconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    }
                    .accessibilityLabel("Song actions")
                    .accessibilityIdentifier("songActionsButton")

                    // Settings
                    Button {
                        dismissKeyboard()
                        viewModel.showSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: EditorViewConstants.ControlChrome.iconSize))
                            .foregroundStyle(.secondary)
                            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                    }
                }
            }
            .frame(width: RhymeAITokens.Touch.minimum * 2 + RhymeAITokens.Spacing.xxs, height: RhymeAITokens.Touch.minimum)
        }
    }
}

private struct RewriteAccessoryHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = EditorViewConstants.EditorLayout.noAccessoryHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InlineRewriteReviewBar: View {
    @Environment(\.appAppearanceStyle) private var appearance

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
                        .scaleEffect(EditorViewConstants.RewriteReview.progressScale)
                } else {
                    Image(systemName: error == nil ? "sparkles" : "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                }

                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .lineLimit(EditorViewConstants.RewriteReview.statusLineLimit)
                    .minimumScaleFactor(EditorViewConstants.RewriteReview.statusMinimumScale)
            }
            .foregroundStyle(error == nil ? appearance.palette.action : appearance.palette.error)
            .frame(maxWidth: .infinity, alignment: .leading)

            if error != nil {
                Button("Retry", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.palette.action)
                    .frame(minWidth: EditorViewConstants.RewriteReview.actionButtonMinWidth, minHeight: RhymeAITokens.Touch.minimum)
                    .buttonStyle(.rhymePress)
            } else if preview != nil {
                Button("Apply", action: onApply)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(appearance.palette.onAction)
                    .frame(minWidth: EditorViewConstants.RewriteReview.actionButtonMinWidth, minHeight: RhymeAITokens.Touch.minimum)
                    .background(appearance.palette.action, in: Capsule())
                    .buttonStyle(.rhymePress)
                Button {
                    onRetry()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(appearance.palette.action)
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Regenerate rewrite")
            }

            Button("Cancel", action: onCancel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: RhymeAITokens.Spacing.xxl, minHeight: RhymeAITokens.Touch.minimum)
                .buttonStyle(.rhymePress)
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .padding(.vertical, RhymeAITokens.Spacing.xs)
        .frame(maxWidth: RhymeAITokens.Layout.drawerMaxWidth)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill, tint: .indigo.opacity(EditorViewConstants.RewriteReview.surfaceTintOpacity), fallbackOpacity: EditorViewConstants.RewriteReview.surfaceFallbackOpacity)
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
        VStack(spacing: EditorViewConstants.Wordmark.verticalSpacing) {
            Text("UnBlock")
                .font(.body.weight(.semibold))
                .lineLimit(1)

            ScribbleUnderline()
                .frame(width: EditorViewConstants.Wordmark.underlineWidth, height: EditorViewConstants.Wordmark.underlineHeight)
        }
    }
}

private struct ScribbleUnderline: View {
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: EditorViewConstants.Scribble.point(EditorViewConstants.Scribble.start, in: size))
            path.addLine(to: EditorViewConstants.Scribble.point(EditorViewConstants.Scribble.firstPeak, in: size))
            path.addLine(to: EditorViewConstants.Scribble.point(EditorViewConstants.Scribble.centerDip, in: size))
            path.addLine(to: EditorViewConstants.Scribble.point(EditorViewConstants.Scribble.secondPeak, in: size))
            path.addLine(to: EditorViewConstants.Scribble.point(EditorViewConstants.Scribble.end, in: size))

            context.stroke(
                path,
                with: .color(appearance.palette.onAction.opacity(EditorViewConstants.Scribble.strokeOpacity)),
                style: StrokeStyle(lineWidth: EditorViewConstants.Scribble.strokeWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }
}


#Preview {
    EditorView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: [SongProject.self, TrashedSongProject.self, SyncDeletionRecord.self], inMemory: true)
}
