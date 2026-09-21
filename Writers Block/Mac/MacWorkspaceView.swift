import AppKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MacWorkspaceView: View {
    @EnvironmentObject private var editor: EditorViewModel
    @Environment(\.modelContext) private var context
    @Environment(\.openSettings) private var openSettings
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @Query(sort: \TrashedSongProject.deletedAt, order: .reverse) private var trash: [TrashedSongProject]
    @AppStorage(AppAppearanceStyle.storageKey) private var appearanceRaw = AppAppearanceStyle.ink.rawValue
    @AppStorage("macLastSongID") private var lastSongID = ""
    @State private var search = ""
    @State private var showingTrash = false
    @State private var deleteCandidate: TrashedSongProject?
    @State private var importing = false
    @State private var showingMemos = false
    @State private var exportDocument: ExportDocument?
    @State private var exportFormat: ExportFormat = .txt
    @State private var exporting = false
    @State private var fileError: String?
    private var appearance: AppAppearanceStyle { .resolve(appearanceRaw) }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                TextField("Search songs", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal)
                Button { newSong() } label: { Label("New Song", systemImage: "plus") }.keyboardShortcut("n").padding(.horizontal)
                List {
                    Section("Songs") {
                        ForEach(projects.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.lyrics.localizedCaseInsensitiveContains(search) }) { project in
                            Button {
                                guard editor.saveCurrentProject() else { return }
                                editor.voiceMemoService.stopRecording()
                                editor.voiceMemoService.stopPlayback()
                                editor.loadProject(project)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(project.title).font(.headline).lineLimit(1)
                                    Text(project.updatedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(project.id == editor.currentProjectId ? appearance.palette.raisedSurface : Color.clear)
                            .contextMenu {
                                Button("Move to Trash", role: .destructive) {
                                    if editor.saveCurrentProject() { _ = editor.moveProjectToTrash(project) }
                                }
                            }
                        }
                    }
                }.scrollContentBackground(.hidden)
                HStack {
                    Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    Spacer()
                    Button { showingTrash = true } label: { Label("Trash", systemImage: "trash") }
                }.padding()
                Text("Saved on this Mac").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
            }
            .padding(.top, 16)
            .navigationSplitViewColumnWidth(min: 210, ideal: 248, max: 320)
            .background(appearance.palette.surface)
        } detail: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Untitled song", text: $editor.title)
                        .font(.system(size: 32, weight: .bold, design: .serif)).textFieldStyle(.plain)
                        .accessibilityIdentifier("macSongTitle").padding(.horizontal, 28).padding(.top, 24)
                    TextField("Theme or feeling", text: $editor.theme).textFieldStyle(.plain).foregroundStyle(.secondary)
                        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 12)
                    MacLyricsTextView(editor: editor, appearance: appearance)
                    HStack {
                        Text("\(editor.wordCount) words · \(editor.syllableCount) syllables")
                        Spacer()
                        Text(editor.saveStatus == .saved ? "Saved" : editor.saveStatus == .saving ? "Saving…" : "")
                    }.font(.caption).foregroundStyle(.secondary).padding(16)
                }.frame(minWidth: 340).background(appearance.palette.canvas)
                if editor.showAssistantSheet {
                    Divider()
                    MacAssistantView().frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
                }
            }
            .foregroundStyle(appearance.palette.primaryInk)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button(format.label) { prepareExport(format) }
                        }
                    } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    Button { editor.showAssistantSheet.toggle() } label: { Label("Assistant", systemImage: "sidebar.right") }
                    Button { showingMemos.toggle() } label: { Label("Voice Memos", systemImage: "mic") }
                        .popover(isPresented: $showingMemos) { MacVoiceMemosView().environmentObject(editor) }
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .tint(appearance.palette.action)
        .task {
            editor.modelContext = context
            if editor.showWelcome, let project = projects.first(where: { $0.id == lastSongID }) { editor.loadProject(project) }
        }
        .onChange(of: editor.title) { editor.triggerAutoSave() }
        .onChange(of: editor.theme) { editor.triggerAutoSave() }
        .onChange(of: editor.currentProjectId) { _, id in lastSongID = id ?? "" }
        .background(MacWindowSaveGuard(editor: editor))
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try ProjectImportData.read(from: url)
                guard editor.saveCurrentProject() else { return }
                _ = editor.importProject(try LyricsExporter.decodeJsonExport(data))
            } catch { fileError = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: exportFormat.contentType, defaultFilename: editor.title.isEmpty ? "Untitled" : editor.title) { result in
            if case .failure(let error) = result { fileError = error.localizedDescription }
        }
        .alert("File operation failed", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("OK") { fileError = nil }
        } message: { Text(fileError ?? "") }
        .safeAreaInset(edge: .bottom) {
            if let error = editor.errorMessage, !editor.showAssistantSheet {
                HStack { Text(error).font(.caption); Spacer(); Button("Dismiss") { editor.errorMessage = nil } }
                    .padding(12).background(appearance.palette.raisedSurface)
            }
        }
        .sheet(isPresented: $showingTrash) { trashView }
        .sheet(item: $editor.cloudAISharingRequest, onDismiss: { editor.cancelCloudAISharing() }) { request in
            VStack(alignment: .leading, spacing: 20) {
                Text("Share lyrics with \(request.provider.displayName)?").font(.title2.bold())
                Text(request.scope == .wholeSong ? "Your entire song will be sent to this provider for \(request.purpose)." : "Your selected lyrics and nearby song context will be sent to this provider for \(request.purpose).")
                HStack {
                    Button("Cancel", role: .cancel) { editor.cancelCloudAISharing() }
                    Spacer()
                    Button("Allow and Continue") { editor.approveCloudAISharing(request) }.keyboardShortcut(.defaultAction)
                }
            }.padding(28).frame(width: 450)
        }
        .sheet(isPresented: Binding(get: { editor.rewriteLoading || editor.rewritePreview != nil || editor.rewriteError != nil }, set: { if !$0 { editor.dismissRewrite() } })) {
            MacRewriteView()
        }
    }

    private func newSong() { if editor.saveCurrentProject() { editor.voiceMemoService.stopRecording(); editor.voiceMemoService.stopPlayback(); editor.newProject() } }
    private func prepareExport(_ format: ExportFormat) {
        do {
            exportDocument = ExportDocument(data: try LyricsExporter.data(for: editor.snapshotForExport(), format: format))
            exportFormat = format
            exporting = true
        } catch { fileError = error.localizedDescription }
    }

    private var trashView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Trash").font(.title.bold()); Spacer(); Button("Done") { showingTrash = false } }
            Text("Songs stay in Trash for 30 days.").foregroundStyle(.secondary)
            List(trash) { project in
                HStack {
                    Text(project.title)
                    Spacer()
                    Button("Restore") { _ = editor.restoreTrashedProject(project) }
                    Button("Delete Permanently", role: .destructive) { deleteCandidate = project }
                }
            }
        }.padding(24).frame(width: 620, height: 440)
        .confirmationDialog("Permanently delete this song?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } })) {
            Button("Delete Permanently", role: .destructive) {
                if let project = deleteCandidate { _ = editor.permanentlyDeleteTrashedProject(project) }
                deleteCandidate = nil
            }
        } message: { Text("This cannot be undone.") }
    }
}

private struct MacAssistantView: View {
    @EnvironmentObject private var editor: EditorViewModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text("UnBlock").font(.title2.bold()); Spacer(); Button { editor.showAssistantSheet = false } label: { Image(systemName: "xmark") }.accessibilityLabel("Close assistant") }
                Text("\(editor.selectedProvider.displayName) · \(editor.selectedModel.displayName)").font(.caption).foregroundStyle(.secondary)
                Picker("Rhyme scheme", selection: $editor.rhymeScheme) {
                    ForEach(RhymeScheme.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if editor.rhymeScheme == .custom { TextField("Custom pattern", text: $editor.customRhymeScheme) }
                Picker("Rhyme type", selection: $editor.rhymeType) {
                    ForEach(RhymeType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Complexity", selection: $editor.rhymeComplexity) {
                    ForEach(RhymeComplexity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Use whole song context", isOn: Binding(get: { editor.useWholeSongContext }, set: editor.saveUseWholeSongContext))
                if editor.isLoading {
                    HStack { ProgressView().controlSize(.small); Text("Writing suggestions…"); Spacer(); Button("Cancel") { editor.cancelSuggestions() } }
                } else {
                    Button("Get Suggestions") { editor.getSuggestions() }.buttonStyle(.borderedProminent)
                }
                if let error = editor.errorMessage {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Open Settings") { openSettings() }
                    Button("Try Again") { editor.getSuggestions() }
                }
                ForEach(editor.suggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(suggestion.text).textSelection(.enabled)
                        if let label = suggestionRhymeBadgeLabel(rhymeTier: suggestion.tier, isHookRepeat: suggestion.isHookRepeat) { Text(label).font(.caption).foregroundStyle(.secondary) }
                        Button("Insert") { editor.insertSuggestion(suggestion.text) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                Divider()
                Text("Rewrite selection").font(.headline)
                Text(editor.selectedRange.length == 0 ? "Select lyrics to rewrite them." : "Preview a rewrite before replacing your selection.").font(.caption).foregroundStyle(.secondary)
                ForEach(RewriteAction.allCases) { action in
                    Button(action.label) { editor.requestRewrite(action) }.disabled(editor.selectedRange.length == 0 || editor.rewriteLoading)
                }
                if let selection = editor.singleWordSelection {
                    Divider()
                    Text("Word analysis").font(.headline)
                    let prosody = ProsodyAnalyzer.analyzeWord(selection.word)
                    Text("\(selection.word) · \(prosody.syllableCount) syllables")
                    Text(prosody.ipa).font(.title3)
                    Text("Stress: " + prosody.stressPattern.map { $0 == 0 ? "unstressed" : "stressed" }.joined(separator: " · ")).font(.caption)
                }
            }.padding(20)
        }
    }
}

private struct MacRewriteView: View {
    @EnvironmentObject private var editor: EditorViewModel
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Rewrite preview").font(.title2.bold())
            if editor.rewriteLoading { ProgressView("Rewriting selection…") }
            if let original = editor.rewriteOriginal { Text("Original").font(.headline); Text(original).foregroundStyle(.secondary) }
            if let preview = editor.rewritePreview { Text("Proposed").font(.headline); ScrollView { Text(preview).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } }
            if let error = editor.rewriteError { Text(error).foregroundStyle(.red); Button("Open Settings") { editor.dismissRewrite(); openSettings() }; Button("Try Again") { editor.retryRewrite() } }
            HStack {
                Button("Cancel") { editor.dismissRewrite() }.keyboardShortcut(.cancelAction)
                Spacer()
                if editor.rewritePreview != nil { Button("Apply Rewrite") { editor.applyRewrite() }.keyboardShortcut(.defaultAction) }
            }
        }.padding(28).frame(width: 540, height: 480)
    }
}
