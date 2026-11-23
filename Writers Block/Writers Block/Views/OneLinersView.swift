import SwiftData
import SwiftUI

/// The pool of stray lines, newest first. Nothing here belongs to a song until
/// the writer sends it to one.
struct OneLinersView: View {
    var onDismiss: () -> Void
    /// This screen was opened from outside the app and opens the captures shortcuts and widgets ask for.
    var takesRequests = false

    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    /// The Mac window keeps the reading width of regular width.
    private let isRegularWidth = true
    #else
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(sort: \OneLiner.createdAt, order: .reverse) private var lines: [OneLiner]
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @State private var searchText = ""
    @AppStorage(DominantHand.storageKey) private var dominantHandRawValue = DominantHand.right.rawValue
    @Environment(\.layoutDirection) private var layoutDirection
    @FocusState private var searchFocused: Bool
    @State private var capture: OneLinerCaptureMode?
    @State private var sendingLine: OneLiner?
    #if os(macOS)
    @State private var selectedLineID: String?
    #endif
    @State private var toast: Toast?
    @State private var player = OneLinerPlayer()

    private struct Toast: Identifiable {
        let id = UUID()
        let message: String
        var systemImage: String? = nil
        var action: (label: String, run: () -> Void)? = nil
    }

    private var palette: AppAppearancePalette { appearance.palette }
    private var store: OneLinersStore {
        var store = OneLinersStore(context: modelContext)
        store.onTrashed = { [viewModel] in viewModel.scheduleTrashPurge() }
        return store
    }
    private var filteredLines: [OneLiner] { OneLinersStore.filter(lines, query: searchText) }

    private var projectTitles: [String: String] {
        Dictionary(projects.map { ($0.id, $0.title.isEmpty ? "Untitled Song" : $0.title) }) { first, _ in first }
    }

    var body: some View {
        ZStack {
            AppWritingBackground()

            VStack(alignment: .leading, spacing: 0) {
                #if !os(macOS)
                // On the Mac the window's sidebar leads back to the songs.
                topBar
                #endif
                if !pageScrolls {
                    header
                        .padding(.horizontal, RhymeAITokens.Rhythm.standard)
                        .padding(.top, RhymeAITokens.Rhythm.standard)
                }

                #if os(macOS)
                // Record and Type sit in the header row on the Mac.
                list
                #else
                if pageScrolls {
                    // Below the list, not over it, so no row or caption sits under the actions at rest.
                    list
                    floatingActions
                        .frame(maxWidth: .infinity, alignment: dominantHand.clusterAlignment(in: layoutDirection))
                } else {
                    list
                        .overlay(alignment: dominantHand.clusterAlignment(in: layoutDirection)) { floatingActions }
                }
                #endif

                if !pageScrolls {
                    footer
                        .padding(.horizontal, RhymeAITokens.Rhythm.standard)
                        .padding(.bottom, RhymeAITokens.Rhythm.related)
                }
            }
            .frame(maxWidth: isRegularWidth ? RhymeAITokens.Layout.editorMaxWidth : .infinity)

            if let toast {
                toastView(toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, RhymeAITokens.Spacing.lg)
                    // Clear the floating Record and Type actions (in the header on the Mac).
                    .padding(.bottom, Self.toastBottomInset)
                    .transition(reduceMotion ? .opacity : .offset(y: RhymeAITokens.Spacing.lg).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        // The background opts out of hit testing; without a shape, taps on
        // blank parts of the screen reach the songs drawer underneath.
        .contentShape(Rectangle())
        .foregroundStyle(palette.primaryInk)
        .onAppear { try? store.purgeExpired() }
        .onChange(of: OneLinerRouter.shared.pending, initial: true) { _, _ in takeRequest() }
        .onDisappear { player.stop() }
        .onChange(of: player.lastError) { _, message in
            guard let message else { return }
            player.lastError = nil
            showToast(Toast(message: message))
        }
        .sheet(item: $capture) { mode in
            OneLinerCaptureView(
                mode: mode,
                pendingRoot: store.pendingRoot,
                microphoneBusy: viewModel.voiceMemoService.isRecording
            ) { saved in
                // A throw keeps the sheet open with its words and take.
                if case .edit(let line) = mode {
                    try store.updateText(line, to: saved.text)
                    showToast(Toast(message: "Line updated", systemImage: "checkmark"))
                } else {
                    try store.add(text: saved.text, take: saved.take, audioDuration: saved.audioDuration)
                    showToast(Toast(message: "Saved to One Liners", systemImage: "checkmark"))
                }
            }
            .environment(\.appAppearanceStyle, appearance)
        }
        .sheet(item: $sendingLine) { line in
            songPicker(for: line)
                .environment(\.appAppearanceStyle, appearance)
        }
    }

    // MARK: - Header

    private var topBar: some View {
        ZStack {
            Text("One Liners")
                .font(.headline)
                .accessibilityHidden(true)
            HStack {
                Button(action: onDismiss) {
                    HStack(spacing: RhymeAITokens.Spacing.xxs) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                        // At accessibility sizes the label ran into the centred title.
                        if !dynamicTypeSize.isAccessibilitySize {
                            Text("Songs")
                        }
                    }
                    .foregroundStyle(palette.secondaryInk)
                    .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Back to songs")
                Spacer()
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.sm)
        .padding(.top, RhymeAITokens.Spacing.xs)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.related) {
            #if os(macOS)
            HStack(alignment: .firstTextBaseline, spacing: RhymeAITokens.Spacing.xs) {
                title
                Spacer(minLength: RhymeAITokens.Spacing.sm)
                macCaptureButton("Record", systemImage: "mic.fill", label: "Record a one liner") {
                    viewModel.voiceMemoService.stopPlayback()
                    openCapture(.record)
                }
                macCaptureButton("Type", systemImage: "keyboard", label: "Type a one liner") {
                    openCapture(.type)
                }
            }
            #else
            title
            #endif
            Text("\(Self.lineCountText(lines.count)), newest first. Nothing here belongs to a song until you send it.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryInk)
                #if !os(macOS)
                .fixedSize(horizontal: false, vertical: true)
                #endif
            searchField
        }
    }

    private var title: some View {
        Text("One Liners")
            .font(.largeTitle.weight(.bold))
            .fontDesign(.serif)
            .accessibilityAddTraits(.isHeader)
    }

    #if os(macOS)
    private static let toastBottomInset = RhymeAITokens.Rhythm.standard
    private static let listBottomInset: CGFloat = 0

    /// A standard Mac push button: no floating chrome, the 28pt Mac target.
    private func macCaptureButton(_ title: String, systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(minHeight: RhymeAITokens.Touch.minimum)
        }
        .buttonStyle(.bordered)
        .help(label)
        .accessibilityLabel(label)
    }
    #else
    private static let toastBottomInset = RhymeAITokens.Rhythm.primary + RhymeAITokens.Rhythm.section + RhymeAITokens.Rhythm.standard
    private static let listBottomInset = RhymeAITokens.Rhythm.primary + RhymeAITokens.Rhythm.section
    #endif

    private var footer: some View {
        #if os(macOS)
        Text("Right-click a line to send it to a song or move it to Trash. Used lines stay.")
            .font(.caption)
            .foregroundStyle(palette.secondaryInk)
        #else
        Text("Swipe right to send to a song, left to trash. Used lines stay.")
            .font(.caption)
            .foregroundStyle(palette.secondaryInk)
        #endif
    }

    /// At accessibility sizes the header and footer scroll with the list, as
    /// one page under the floating actions; pinned, they left the list no room.
    private var pageScrolls: Bool { dynamicTypeSize.isAccessibilitySize }

    private func pageRow(_ content: some View, top: CGFloat, bottom: CGFloat) -> some View {
        content
            .listRowInsets(EdgeInsets(
                top: top,
                leading: RhymeAITokens.Rhythm.standard,
                bottom: bottom,
                trailing: RhymeAITokens.Rhythm.standard
            ))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private var searchField: some View {
        HStack(spacing: RhymeAITokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.secondaryInk)
                .accessibilityHidden(true)
            TextField(
                "Search one liners",
                text: $searchText,
                prompt: Text("Search one liners").foregroundStyle(palette.placeholder)
            )
            .textInputAutocapitalization(.never)
            .submitLabel(.search)
            .focused($searchFocused)
            #if os(macOS)
            // The row draws the field; the Mac's default bezel would add a second outline.
            .textFieldStyle(.plain)
            #endif
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(palette.secondaryInk)
                        .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.rhymePress)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, RhymeAITokens.Rhythm.standard)
        .frame(minHeight: RhymeAITokens.Touch.minimum)
        .surfaceLevel(.raised, shape: Capsule())
    }

    // MARK: - List

    private var list: some View {
        #if os(macOS)
        // The Mac has no swipes: the same two actions on a right-click, and
        // Delete moves the selected line to Trash as a trailing swipe does.
        styledList(List(selection: $selectedLineID) { listRows }
            .onDeleteCommand {
                if let line = filteredLines.first(where: { $0.id == selectedLineID }) { trash(line) }
            })
        #else
        styledList(List { listRows })
        #endif
    }

    @ViewBuilder
    private var listRows: some View {
        if pageScrolls {
            pageRow(header, top: RhymeAITokens.Rhythm.standard, bottom: 0)
        }
        if lines.isEmpty {
            emptyState(title: "No one liners yet.", caption: "\(PlatformWording.tap) Record or Type to catch a line before it slips away.")
        } else if filteredLines.isEmpty {
            emptyState(title: "No one liners match your search.", caption: nil)
        } else {
            ForEach(filteredLines, id: \.id) { line in
                row(line)
                    // A raised slab per line, 2pt apart, inset so the text keeps its 21pt margin.
                    .listRowBackground(
                        Color.clear
                            .surfaceLevel(.raised, cornerRadius: RhymeAITokens.Radius.md)
                            .padding(.vertical, 1)
                            .padding(.horizontal, RhymeAITokens.Rhythm.tight)
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: RhymeAITokens.Rhythm.related,
                        leading: RhymeAITokens.Rhythm.standard,
                        bottom: RhymeAITokens.Rhythm.related,
                        trailing: RhymeAITokens.Rhythm.standard
                    ))
                    .swipeActions(edge: .leading, allowsFullSwipe: !line.text.isEmpty) {
                        Button {
                            // Released first, or the sheet hands focus (and the
                            // keyboard) back to the search field when it closes.
                            searchFocused = false
                            sendingLine = line
                        } label: {
                            Label("Send to song", systemImage: "arrow.turn.down.right")
                        }
                        .tint(palette.action)
                        // An audio-only line has no words to send yet.
                        .disabled(line.text.isEmpty)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            trash(line)
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                    }
                    #if os(macOS)
                    .contextMenu {
                        Button("Send to Song…") { sendingLine = line }
                            .disabled(line.text.isEmpty)
                        Button("Move to Trash", role: .destructive) { trash(line) }
                    }
                    #endif
            }
        }
        if pageScrolls {
            pageRow(footer, top: RhymeAITokens.Rhythm.related, bottom: RhymeAITokens.Rhythm.related)
        }
    }

    private func styledList(_ list: some View) -> some View {
        list
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            // Room under the last row for the floating Record and Type actions.
            .contentMargins(.bottom, pageScrolls ? 0 : Self.listBottomInset, for: .scrollContent)
            .padding(.top, RhymeAITokens.Rhythm.related)
            .rhymeAnimation(RhymeAITokens.Motion.state, value: lines.isEmpty)
    }

    private func row(_ line: OneLiner) -> some View {
        let usedTitle = line.usedInProjectId.flatMap { projectTitles[$0] }
        let isVoiceOnly = line.text.isEmpty
        let audioURL = line.audioFileName.map { store.audioURL(fileName: $0) }
        let availability = Self.takeAvailability(audioURL)
        return HStack(alignment: .center, spacing: RhymeAITokens.Spacing.xs) {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                Text(isVoiceOnly ? "Voice line" : line.text)
                    .font(.callout)
                    .italic(isVoiceOnly)
                    .foregroundStyle(line.usedInProjectId == nil && !isVoiceOnly ? palette.primaryInk : palette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if availability == .missing {
                    Text("Voice take unavailable on this device")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryInk)
                }

                if isVoiceOnly {
                    let editHint = availability == .missing
                        ? "\(PlatformWording.tap) to type the words."
                        : "Transcribe or type the words first. \(PlatformWording.tap) to add them."
                    Text(editHint)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryInk)
                }

                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    Text(Self.relativeDateText(line.createdAt))
                    if line.audioFileName != nil {
                        HStack(spacing: RhymeAITokens.Spacing.xxs) {
                            Image(systemName: "mic")
                                .fontWeight(.medium)
                            Text(OneLinerCaptureView.durationText(line.audioDuration))
                                .monospacedDigit()
                        }
                    }
                    if let usedTitle {
                        Text("In \(usedTitle)")
                            .lineLimit(1)
                            .padding(.horizontal, RhymeAITokens.Spacing.xs)
                            .padding(.vertical, 1)
                            .background(palette.raisedSurface, in: Capsule())
                    }
                    Spacer(minLength: RhymeAITokens.Spacing.xs)
                    if !isVoiceOnly {
                        Text(Self.prosodyBadge(line))
                            .monospaced()
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryInk)
            }
            .contentShape(Rectangle())
            .onTapGesture { openCapture(.edit(line)) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Edits the words")
            .accessibilityAction { openCapture(.edit(line)) }

            if let url = audioURL, availability == .local(url) || player.playingURL == url {
                playButton(url)
            }
        }
    }

    enum TakeAvailability: Equatable {
        case noTake
        case missing
        case local(URL)
    }

    static func takeAvailability(_ url: URL?) -> TakeAvailability {
        guard let url else { return .noTake }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return .missing }
        return .local(url)
    }

    private func playButton(_ url: URL) -> some View {
        let isPlaying = player.playingURL == url
        return Button {
            if player.playingURL != url {
                guard Self.takeAvailability(url) == .local(url) else {
                    showToast(Toast(message: "Voice take unavailable on this device"))
                    return
                }
                viewModel.voiceMemoService.stopPlayback()
            }
            if !player.toggle(url, memoRecording: viewModel.voiceMemoService.isRecording) {
                showToast(Toast(message: "Finish recording first"))
            }
        } label: {
            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(isPlaying ? palette.recording : palette.secondaryInk)
                .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                .overlay(Circle().strokeBorder(palette.outline, lineWidth: 1))
        }
        // Borderless: in a List a plain button would take taps for the whole row.
        .buttonStyle(.borderless)
        .accessibilityLabel(isPlaying ? "Stop take" : "Play take")
    }

    private func emptyState(title: String, caption: String?) -> some View {
        VStack(spacing: RhymeAITokens.Spacing.xs) {
            Image(systemName: "text.quote")
                .font(.title2)
                .foregroundStyle(palette.secondaryInk)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryInk)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryInk)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RhymeAITokens.Touch.minimum)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .transition(.opacity)
    }

    // MARK: - Floating actions

    #if !os(macOS)
    private var dominantHand: DominantHand { DominantHand.resolve(dominantHandRawValue) }

    /// Shaped like the editor's UnBlock + mic cluster: the wide Record pill
    /// inside, the round Type button outermost at the dominant hand's edge.
    private var floatingActions: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            if dominantHand.usesLeadingEdge(in: layoutDirection) {
                typeButton
                recordButton
            } else {
                recordButton
                typeButton
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.md)
        .padding(.bottom, RhymeAITokens.Spacing.md)
        // The editor's floating-action clamp, on every width: Type is a fixed 56pt circle
        // whose glyph would otherwise outgrow it and run into Record.
        .dynamicTypeSize(pageScrolls ? .large : dynamicTypeSize)
    }

    private var typeButton: some View {
        Button {
            openCapture(.type)
        } label: {
            Image(systemName: "keyboard")
                .font(.title3.weight(.medium))
                .foregroundStyle(palette.primaryInk)
                .frame(width: RhymeAITokens.Touch.comfortable, height: RhymeAITokens.Touch.comfortable)
                .background(palette.surface, in: Circle())
                .overlay(Circle().strokeBorder(palette.outline, lineWidth: 1))
                .chromeShadow()
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel("Type a one liner")
    }

    private var recordButton: some View {
        Button {
            viewModel.voiceMemoService.stopPlayback()
            openCapture(.record)
        } label: {
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                Image(systemName: "mic.fill")
                    .font(.title3.weight(.medium))
                Text("Record")
                    .font(.body.weight(.semibold))
            }
            .padding(.horizontal, RhymeAITokens.Spacing.md)
            .frame(minWidth: EditorViewConstants.UnBlockChrome.expandedButtonWidth, minHeight: RhymeAITokens.Touch.comfortable)
            .appearanceActionSurface(cornerRadius: RhymeAITokens.Radius.pill)
            .chromeShadow()
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel("Record a one liner")
    }
    #endif

    /// A Record or Type from outside opens its capture; while one is opening or open
    /// it is left for that capture, which keeps its words and says so.
    private func takeRequest() {
        let router = OneLinerRouter.shared
        guard takesRequests, capture == nil, router.handler(screenPresented: true) == .screen,
              let action = router.take([.record, .type, .open]) else { return }
        switch action {
        case .record:
            viewModel.voiceMemoService.stopPlayback()
            openCapture(.record)
        case .type:
            openCapture(.type)
        case .open, .stopRecording:
            break
        }
    }

    /// A take playing would reach the microphone, so playback stops before any capture opens.
    private func openCapture(_ mode: OneLinerCaptureMode) {
        player.stop()
        capture = mode
    }

    // MARK: - Send to song

    private func songPicker(for line: OneLiner) -> some View {
        NavigationStack {
            List {
                if projects.isEmpty {
                    Text("No songs yet. Create one from the songs drawer first.")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryInk)
                        .listRowBackground(Color.clear)
                }
                ForEach(projects, id: \.id) { project in
                    Button {
                        send(line, to: project)
                    } label: {
                        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                            Text(project.title.isEmpty ? "Untitled Song" : project.title)
                                .font(.headline)
                                .fontDesign(.serif)
                                .foregroundStyle(palette.primaryInk)
                            Text(project.id == viewModel.currentProjectId ? "Open now · goes in at the cursor" : "Goes in as the last line")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryInk)
                        }
                        .frame(maxWidth: .infinity, minHeight: RhymeAITokens.Touch.minimum, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.rhymePress)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(palette.surface)
            .navigationTitle("Send to song")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { sendingLine = nil }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func send(_ line: OneLiner, to project: SongProject) {
        sendingLine = nil
        let title = project.title.isEmpty ? "Untitled Song" : project.title
        do {
            try store.sendToSong(line, project: project, editor: viewModel)
            showToast(Toast(message: "Sent to \u{201c}\(title)\u{201d}", systemImage: "checkmark"))
        } catch let error as OneLinersStoreError {
            showToast(Toast(message: error.errorDescription ?? "Couldn't send this line. Try again."))
        } catch {
            showToast(Toast(message: "Couldn't send this line. Try again."))
        }
    }

    private func trash(_ line: OneLiner) {
        if let fileName = line.audioFileName, player.playingURL == store.audioURL(fileName: fileName) { player.stop() }
        do {
            let trashed = try store.trash(line)
            showToast(Toast(message: "Line moved to Trash", action: ("Undo", { _ = try? store.restore(trashed) })))
        } catch {
            showToast(Toast(message: "Couldn't move this line to Trash."))
        }
    }

    // MARK: - Toast

    private func showToast(_ next: Toast) {
        withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) {
            toast = next
        }
    }

    /// Same look and timing as the songs drawer's toast.
    private func toastView(_ toast: Toast) -> some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            if let systemImage = toast.systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.success.opacity(EditorViewConstants.TopBar.savedStatusOpacity))
                    .accessibilityHidden(true)
            }
            Text(toast.message)
                .font(.subheadline)
                .foregroundStyle(palette.primaryInk)
                .lineLimit(2)
            Spacer(minLength: RhymeAITokens.Spacing.sm)
            if let action = toast.action {
                Button {
                    withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                        action.run()
                        self.toast = nil
                    }
                } label: {
                    Text(action.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.action)
                        .frame(minWidth: RhymeAITokens.Touch.minimum, minHeight: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.rhymePress)
            }
        }
        .padding(.horizontal, RhymeAITokens.Spacing.lg)
        .padding(.vertical, RhymeAITokens.Spacing.sm)
        .frame(minHeight: RhymeAITokens.Touch.minimum)
        .frame(maxWidth: RhymeAITokens.Layout.assistantReadableWidth)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg)
        .shadow(color: palette.primaryInk.opacity(0.3), radius: 14, y: 4)
        .accessibilityElement(children: .combine)
        .task(id: toast.id) {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard self.toast?.id == toast.id else { return }
            withRhymeAnimation(RhymeAITokens.Motion.dismiss, reduceMotion: reduceMotion) {
                self.toast = nil
            }
        }
    }

    // MARK: - Formatting

    static func lineCountText(_ count: Int) -> String {
        count == 1 ? "1 line" : "\(count) lines"
    }

    /// "10 syl · bathroom": the syllable count and the end word the line rhymes on.
    static func prosodyBadge(_ line: OneLiner) -> String {
        let endWord = RhymeConstraint.lineEndWord(line.text)
        return endWord.isEmpty ? "\(line.syllableCount) syl" : "\(line.syllableCount) syl · \(endWord)"
    }

    /// "Just now", "5 min ago", "Tue", "Oct 14", "Oct 14, 2025".
    static func relativeDateText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "Just now" }
        if calendar.isDate(date, inSameDayAs: now) {
            return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)
        }
        if elapsed < 6 * 24 * 60 * 60 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
