import SwiftUI

struct RhymeSchemeDisplayView: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let rhymeContext: RhymeContext
    let activeScheme: String

    var body: some View {
        let rows = rhymeSchemeRows(context: rhymeContext, scheme: activeScheme)

        if rows.isEmpty {
            EmptyView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.hairline) {
                    ForEach(rows.indices, id: \.self) { index in
                        let row = rows[index]
                        let isCurrent = row.isCurrent

                        HStack(spacing: RhymeAITokens.Spacing.sm) {
                            Text(row.letter ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(isCurrent ? appearance.palette.action : appearance.palette.secondaryInk.opacity(0.75))
                                .frame(width: RhymeAITokens.Spacing.md, alignment: .leading)

                            if row.line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isCurrent {
                                Text("Next line goes here")
                                    .font(.system(.caption, design: .monospaced))
                                    .italic()
                                    .foregroundColor(.secondary.opacity(0.5))
                            } else {
                                Text(row.line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary.opacity(isCurrent ? 0.9 : 0.6))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }

                            Spacer()
                        }
                        .padding(.vertical, RhymeAITokens.Spacing.hairline)
                    }
                }
                .padding(RhymeAITokens.Spacing.sm)
            }
            .frame(maxHeight: 160)
            .background(appearance.palette.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md)
                    .strokeBorder(appearance.palette.outline, lineWidth: RhymeAITokens.Spacing.hairline)
            )
        }
    }
}
