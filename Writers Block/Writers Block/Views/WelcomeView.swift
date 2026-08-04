import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appAppearanceStyle) private var appearance

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var usesHorizontalCards: Bool { isRegular && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ZStack {
            AppWritingBackground()

            VStack(spacing: 0) {
                Spacer()

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
                    .font(.system(.largeTitle, design: .serif, weight: .bold))
                    .foregroundStyle(appearance.palette.primaryInk)
                    .padding(.bottom, 8)

                // Subtitle
                Text("Your intelligent songwriting companion.\nStart from scratch, load a project, or pick a template.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: RhymeAITokens.Layout.assistantReadableWidth)
                    .padding(.horizontal, RhymeAITokens.Spacing.xl)
                    .padding(.bottom, RhymeAITokens.Spacing.xxl)

                // Action Cards — horizontal on iPad, vertical on iPhone
                Group {
                    if isRegular {
                        HStack(spacing: RhymeAITokens.Spacing.lg) {
                            cardContent
                        }

                        // Title
                        Text("Writers Block")
                            .font(.system(.largeTitle, design: .serif, weight: .bold))
                            .foregroundStyle(appearance.palette.primaryInk)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, RhymeAITokens.Spacing.xl)
                            .padding(.bottom, RhymeAITokens.Spacing.xs)

                        if !dynamicTypeSize.isAccessibilitySize {
                            // Subtitle
                            Text("Your intelligent songwriting companion.\nStart from scratch, load a project, or pick a template.")
                                .font(.body)
                                .foregroundStyle(appearance.palette.secondaryInk)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: RhymeAITokens.Layout.assistantReadableWidth)
                                .padding(.horizontal, RhymeAITokens.Spacing.xl)
                                .padding(.bottom, RhymeAITokens.Spacing.xxl)
                        }

                        // Action Cards — horizontal on iPad, vertical at accessibility sizes.
                        Group {
                            if usesHorizontalCards {
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

                        Spacer(minLength: RhymeAITokens.Spacing.xxl)
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(appearance.palette.primaryInk)
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

    let icon: String
    let title: String
    let subtitle: String
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if compact {
                    // Vertical card layout for iPad horizontal arrangement
                    VStack(spacing: RhymeAITokens.Spacing.sm) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(appearance.palette.primaryInk)
                            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md)

                        VStack(spacing: RhymeAITokens.Spacing.xs) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(appearance.palette.primaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(appearance.palette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(RhymeAITokens.Spacing.md)
                } else {
                    // Horizontal card layout for iPhone
                    HStack(spacing: RhymeAITokens.Spacing.lg) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(appearance.palette.primaryInk)
                            .frame(width: RhymeAITokens.Touch.minimum, height: RhymeAITokens.Touch.minimum)
                            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md)

                        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(appearance.palette.primaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(appearance.palette.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(appearance.palette.secondaryInk)
                            .frame(width: RhymeAITokens.Spacing.lg, height: RhymeAITokens.Spacing.lg)
                    }
                    .padding(RhymeAITokens.Spacing.lg)
                }
            }
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
        }
        .buttonStyle(.rhymePress)
    }
}

#Preview {
    WelcomeView()
        .environmentObject(EditorViewModel())
}
