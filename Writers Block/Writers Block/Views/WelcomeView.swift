import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.appAppearanceStyle) private var appearance

    private var isRegular: Bool { horizontalSizeClass == .regular }
    private var usesHorizontalCards: Bool { isRegular && !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        ZStack {
            AppWritingBackground()

            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? RhymeAITokens.Spacing.md : proxy.size.height * 0.08)

                        if !dynamicTypeSize.isAccessibilitySize {
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
                                .shadow(color: appearance.palette.primaryInk.opacity(0.14), radius: 18, y: 8)
                                .padding(10)
                                .liquidGlassSurface(cornerRadius: 30)
                                .padding(.bottom, RhymeAITokens.Spacing.xl)
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
                            // Subtitle. The non-breaking spaces keep "pick a
                            // template." together, so a narrow screen cannot
                            // strand its last word or two on a line.
                            Text("Your intelligent songwriting companion.\nStart fresh, load a song, or pick\u{00A0}a\u{00A0}template.")
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
                                // Cards stretch to the tallest one so a wrapped
                                // subtitle cannot leave them at unequal heights.
                                HStack(spacing: RhymeAITokens.Spacing.lg) {
                                    cardContent
                                }
                                .fixedSize(horizontal: false, vertical: true)
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
                .accessibilityIdentifier("welcomeScroll")
            }
        }
    }

    // The centred tile layout only suits the side-by-side row. Stacked at
    // accessibility sizes it stretched each card to a third of the screen with
    // its content pinned to the top, so the stack uses the row layout instead.
    @ViewBuilder
    private var cardContent: some View {
        WelcomeCard(
            icon: "plus",
            title: "New Song",
            subtitle: "Start with a blank canvas",
            compact: usesHorizontalCards
        ) {
            viewModel.newProject()
        }

        WelcomeCard(
            icon: "folder",
            title: "Load Song",
            subtitle: "Continue where you left off",
            compact: usesHorizontalCards
        ) {
            viewModel.showProjectsSheet = true
        }

        WelcomeCard(
            icon: "rectangle.grid.2x2",
            title: "Song Templates",
            subtitle: "Start with a structured layout",
            compact: usesHorizontalCards
        ) {
            viewModel.showTemplatesSheet = true
        }

        // The root's full-screen cover is the one path to the screen, so its routing guards apply.
        WelcomeCard(
            icon: "text.quote",
            title: "One Liners",
            subtitle: "Catch a line before it goes",
            compact: usesHorizontalCards,
            action: { OneLinerRouter.shared.request(.open) },
            actions: { OneLinerQuickActions() }
        )
    }
}

/// Record and Type straight from the first screen, styled like the One Liners screen's floating actions.
private struct OneLinerQuickActions: View {
    @Environment(\.appAppearanceStyle) private var appearance

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: RhymeAITokens.Rhythm.related) { pills }
            VStack(alignment: .leading, spacing: RhymeAITokens.Rhythm.related) { pills }
        }
    }

    @ViewBuilder
    private var pills: some View {
        Button {
            OneLinerRouter.shared.request(.record)
        } label: {
            Label("Record", systemImage: "mic.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .frame(minHeight: RhymeAITokens.Touch.minimum)
                .appearanceActionSurface(cornerRadius: RhymeAITokens.Touch.minimum / 2)
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel("Record a one liner")
        .accessibilityIdentifier("welcomeRecordOneLiner")

        Button {
            OneLinerRouter.shared.request(.type)
        } label: {
            Label("Type", systemImage: "keyboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(appearance.palette.primaryInk)
                .padding(.horizontal, RhymeAITokens.Spacing.md)
                .frame(minHeight: RhymeAITokens.Touch.minimum)
                .background(appearance.palette.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(appearance.palette.outline, lineWidth: 1))
        }
        .buttonStyle(.rhymePress)
        .accessibilityLabel("Type a one liner")
        .accessibilityIdentifier("welcomeTypeOneLiner")
    }
}

private struct WelcomeCard<Actions: View>: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let icon: String
    let title: String
    let subtitle: String
    var compact: Bool = false
    let action: () -> Void
    /// Buttons of their own below the card's row, so they are not nested in the card's button.
    @ViewBuilder var actions: Actions

    var body: some View {
        if Actions.self == EmptyView.self {
            Button(action: action) {
                row
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
                    .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
            }
            .buttonStyle(.rhymePress)
        } else {
            VStack(alignment: compact ? .center : .leading, spacing: 0) {
                Button(action: action) {
                    row.contentShape(Rectangle())
                }
                .buttonStyle(.rhymePress)

                actions
                    // Under the title and subtitle: past the icon on the row layout.
                    .padding(.leading, compact ? 0 : RhymeAITokens.Spacing.lg * 2 + RhymeAITokens.Touch.minimum)
                    .padding(.horizontal, compact ? RhymeAITokens.Spacing.md : 0)
                    .padding(.bottom, compact ? RhymeAITokens.Spacing.md : RhymeAITokens.Spacing.lg)
            }
            .frame(minHeight: RhymeAITokens.Touch.minimum)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.lg, interactive: true)
        }
    }

    private var row: some View {
        Group {
            if compact {
                // Vertical card layout for iPad horizontal arrangement
                VStack(spacing: RhymeAITokens.Spacing.sm) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(appearance.palette.action)
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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(RhymeAITokens.Spacing.md)
            } else {
                // Horizontal card layout for iPhone
                HStack(spacing: RhymeAITokens.Spacing.lg) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(appearance.palette.action)
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
    }
}

extension WelcomeCard where Actions == EmptyView {
    init(icon: String, title: String, subtitle: String, compact: Bool = false, action: @escaping () -> Void) {
        self.init(icon: icon, title: title, subtitle: subtitle, compact: compact, action: action, actions: { EmptyView() })
    }
}

#Preview {
    WelcomeView()
        .environmentObject(EditorViewModel())
}
