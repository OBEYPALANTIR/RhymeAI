import SwiftUI
import SwiftData
import UIKit

struct EditorView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var keyboardIsVisible = false
    @State private var assistantSheetDragOffset: CGFloat = 0

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                iPadLayout
            } else {
                iPhoneLayout
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            viewModel.modelContext = modelContext
        }
    }

    // MARK: - iPad Layout (split view)

    private var iPadLayout: some View {
        HStack(spacing: 0) {
            // Editor column
            VStack(spacing: 0) {
                topBar
                editorScrollView
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Persistent assistant column
            AssistantPanelView(isInline: true)
                .frame(width: 380)
        }
    }

    // MARK: - iPhone Layout (FAB + sheet)

    private var iPhoneLayout: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                editorScrollView
            }

            assistantFloatingButton
                .zIndex(1)

            assistantSheetOverlay
                .zIndex(2)
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: viewModel.showAssistantSheet)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
        .onChange(of: viewModel.showAssistantSheet) { _, isPresented in
            if isPresented {
                assistantSheetDragOffset = 0
            }
        }
    }

    @ViewBuilder
    private var assistantFloatingButton: some View {
        if !viewModel.showAssistantSheet {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        presentAssistantSheet()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "wand.and.stars")
                                .font(.body.weight(.semibold))
                            Text("UnBlock")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .liquidGlassSurface(cornerRadius: 28, tint: .indigo, interactive: true, fallbackOpacity: 0.35)
                        .shadow(color: .indigo.opacity(0.26), radius: 12, y: 4)
                    }
                    .accessibilityIdentifier("unblockButton")
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
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
                        .padding(.top, proxy.safeAreaInsets.top + 8)

                    AssistantPanelView()
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
            .frame(height: 64)
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(0.45))
                    .frame(width: 42, height: 5)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        assistantSheetDragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        settleAssistantSheetDrag(translation: value.translation.height, sheetHeight: sheetHeight)
                    }
            )
            .accessibilityLabel("Dismiss Assistant")
    }

    private func settleAssistantSheetDrag(translation: CGFloat, sheetHeight: CGFloat) {
        let dragDistance = max(0, translation)
        let closeThreshold = max(0, sheetHeight - 64) * 0.5

        if dragDistance >= closeThreshold {
            withAnimation(.easeInOut(duration: 0.18)) {
                assistantSheetDragOffset = sheetHeight
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                viewModel.showAssistantSheet = false
                assistantSheetDragOffset = 0
            }
        } else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                assistantSheetDragOffset = 0
            }
        }
    }

    private func presentAssistantSheet() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        if keyboardIsVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                showAssistantSheetWithAnimation()
            }
        } else {
            showAssistantSheetWithAnimation()
        }
    }

    private func showAssistantSheetWithAnimation() {
        assistantSheetDragOffset = 0
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            viewModel.showAssistantSheet = true
        }
    }

    // MARK: - Shared Editor Content

    private var editorScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Title Field
                TextField("Song Title...", text: $viewModel.title)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                    .onChange(of: viewModel.title) {
                        viewModel.triggerAutoSave()
                    }

                // Lyrics Editor
                ZStack(alignment: .topLeading) {
                    // Syllable coloring overlay
                    if viewModel.isSyllableColoringEnabled && !viewModel.lyrics.isEmpty {
                        SyllableColoredText(
                            text: viewModel.lyrics,
                            enabled: true
                        )
                        .padding(.horizontal, 20)
                    }

                    // Actual text view
                    LyricsTextView(
                        text: $viewModel.lyrics,
                        onCursorChange: { pos in
                            viewModel.cursorPosition = pos
                        },
                        isTransparentText: viewModel.isSyllableColoringEnabled && !viewModel.lyrics.isEmpty
                    )
                    .frame(minHeight: 400)
                    .padding(.horizontal, 20)
                    .onChange(of: viewModel.lyrics) {
                        viewModel.triggerAutoSave()
                    }
                }

                Spacer(minLength: 200)
            }
            .frame(maxWidth: 740)
            .frame(maxWidth: .infinity)
        }
        .background(Color.black)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Back to Welcome
            Button {
                viewModel.goToStartMenu()
            } label: {
                Image(systemName: "music.quarternote.3")
                    .font(.body)
                    .foregroundStyle(.indigo)
            }

            Divider()
                .frame(height: 16)

            // Projects
            Button {
                viewModel.showProjectsSheet = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption)
                    Text("Projects")
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }

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

            // Settings
            Button {
                viewModel.showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlassSurface(cornerRadius: 0, fallbackOpacity: 0.02)
        .overlay(
            Divider(), alignment: .bottom
        )
    }
}

#Preview {
    EditorView()
        .environmentObject(EditorViewModel())
        .modelContainer(for: SongProject.self, inMemory: true)
}
