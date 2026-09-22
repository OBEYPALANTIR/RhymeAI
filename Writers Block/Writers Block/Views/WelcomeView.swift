import SwiftUI
import SwiftData

struct WelcomeView: View {
    @Query(sort: \SongProject.updatedAt, order: .reverse) private var projects: [SongProject]
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appAppearanceStyle) private var appearance

    private var isRegular: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        ZStack {
            AppWritingBackground()

            GeometryReader { geometry in
                ScrollView {
                    welcomeContent
                        .padding(.vertical, RhymeAITokens.Spacing.xl)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                }
                .accessibilityIdentifier("welcomeScroll")
            }
        }
        .foregroundStyle(appearance.palette.primaryInk)
    }

    private var welcomeContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // App Icon
            Image("BrandIcon")
                .resizable()
                .scaledToFill()
                .frame(width: RhymeAITokens.Touch.prominent, height: RhymeAITokens.Touch.prominent)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: appearance.palette.primaryInk.opacity(0.18), radius: 22, y: 10)
                .padding(10)
                .liquidGlassSurface(cornerRadius: 30, tint: .indigo.opacity(0.06))
                .padding(.bottom, RhymeAITokens.Spacing.xl)

            // Title
            Text("Writers Block")
                .font(.system(.title, design: .serif, weight: .bold))
                .foregroundStyle(appearance.palette.primaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, RhymeAITokens.Spacing.xl)
                .padding(.bottom, 8)

            // Subtitle
            Text("A space for your next song.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: RhymeAITokens.Layout.assistantReadableWidth)
                .padding(.horizontal, RhymeAITokens.Spacing.xl)
                .padding(.bottom, RhymeAITokens.Spacing.xxl)

            if let recent = projects.first {
                Button {
                    viewModel.loadProject(recent)
                } label: {
                    Label("Continue \(recent.title.isEmpty ? "Untitled Song" : recent.title)", systemImage: "arrow.uturn.right")
                        .font(.subheadline.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(minHeight: RhymeAITokens.Touch.minimum)
                }
                .buttonStyle(.rhymePress)
                .accessibilityIdentifier("continueSongButton")
                .padding(.horizontal, RhymeAITokens.Spacing.xl)
                .padding(.bottom, RhymeAITokens.Spacing.md)
            }

            // Action Cards — horizontal on iPad, vertical on iPhone
            Group {
                if isRegular {
                    HStack(spacing: RhymeAITokens.Spacing.lg) {
                        cardContent
                    }
                } else {
                    VStack(spacing: RhymeAITokens.Spacing.lg) {
                        cardContent
                    }
                }
            }
            .frame(maxWidth: RhymeAITokens.Layout.drawerMaxWidth + RhymeAITokens.Layout.drawerMinWidth)
            .padding(.horizontal, RhymeAITokens.Spacing.xl)
            .liquidGlassGroup(spacing: RhymeAITokens.Spacing.lg)

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        WelcomeCard(
            icon: "plus",
            title: "New Song",
            subtitle: "Start with a blank canvas",
            compact: isRegular
        ) {
            viewModel.newProject()
        }

        WelcomeCard(
            icon: "folder",
            title: "Load Song",
            subtitle: "Continue where you left off",
            compact: isRegular
        ) {
            viewModel.showProjectsSheet = true
        }

        WelcomeCard(
            icon: "rectangle.grid.2x2",
            title: "Song Templates",
            subtitle: "Start with a structured layout",
            compact: isRegular
        ) {
            viewModel.showTemplatesSheet = true
        }
    }
}

private struct WelcomeCard: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let icon: String
    let title: String
    let subtitle: String
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact || dynamicTypeSize.isAccessibilitySize {
                    // Vertical card layout for iPad horizontal arrangement
                    VStack(spacing: RhymeAITokens.Spacing.sm) {
                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .accessibilityHidden(true)
                            .foregroundStyle(appearance.palette.primaryInk)
                            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .indigo.opacity(0.16), fallbackOpacity: 0.10)

                        VStack(spacing: RhymeAITokens.Spacing.xs) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(RhymeAITokens.Spacing.md)
                } else {
                    // Horizontal card layout for iPhone
                    HStack(spacing: RhymeAITokens.Spacing.lg) {
                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .accessibilityHidden(true)
                            .foregroundStyle(appearance.palette.primaryInk)
                            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, tint: .indigo.opacity(0.16), fallbackOpacity: 0.10)

                        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .padding(RhymeAITokens.Spacing.lg)
                }
            }
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, tint: .indigo.opacity(0.08), interactive: true)
        }
        .buttonStyle(.rhymePress)
    }
}

#Preview {
    WelcomeView()
        .environmentObject(EditorViewModel())
}
