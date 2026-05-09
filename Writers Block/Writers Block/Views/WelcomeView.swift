import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject private var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isRegular: Bool { horizontalSizeClass == .regular }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Background gradient
            LinearGradient(
                colors: [Color.indigo.opacity(0.1), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // App Icon
                Image("BrandIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 82, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                    .shadow(color: .indigo.opacity(0.32), radius: 22, y: 10)
                    .padding(10)
                    .liquidGlassSurface(cornerRadius: 30, tint: .white.opacity(0.04))
                .padding(.bottom, 32)

                // Title
                Text("Writers Block")
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.bottom, 8)

                // Subtitle
                Text("Your intelligent songwriting companion.\nStart from scratch, load a project, or pick a template.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)

                // Action Cards — horizontal on iPad, vertical on iPhone
                Group {
                    if isRegular {
                        HStack(spacing: 16) {
                            cardContent
                        }
                    } else {
                        VStack(spacing: 16) {
                            cardContent
                        }
                    }
                }
                .frame(maxWidth: 600)
                .padding(.horizontal, 24)

                Spacer()
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
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
                    VStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(.indigo)
                            .frame(width: 44, height: 44)
                            .background(Color.indigo.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                } else {
                    // Horizontal card layout for iPhone
                    HStack(spacing: 16) {
                        Image(systemName: icon)
                            .font(.title2)
                            .foregroundStyle(.indigo)
                            .frame(width: 44, height: 44)
                            .background(Color.indigo.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.5))
                    }
                    .padding(16)
                }
            }
            .liquidGlassSurface(cornerRadius: 16, tint: .indigo.opacity(0.08), interactive: true)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    WelcomeView()
        .environmentObject(EditorViewModel())
}
