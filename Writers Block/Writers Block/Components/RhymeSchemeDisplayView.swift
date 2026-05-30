import SwiftUI

struct RhymeSchemeDisplayView: View {
    let rhymeContext: RhymeContext
    let activeScheme: String

    var body: some View {
        let schemeLetters = Array(activeScheme)

        if schemeLetters.isEmpty || rhymeContext.stanzaLines.isEmpty {
            EmptyView()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.hairline) {
                    ForEach(Array(rhymeContext.stanzaLines.enumerated()), id: \.offset) { index, line in
                        let letter = String(schemeLetters[index % schemeLetters.count])
                        let isCurrent = index == rhymeContext.currentLineIndex

                        HStack(spacing: RhymeAITokens.Spacing.sm) {
                            Text(letter)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(isCurrent ? .indigo : .secondary.opacity(0.4))
                                .frame(width: RhymeAITokens.Spacing.md, alignment: .leading)

                            if line.trimmingCharacters(in: .whitespaces).isEmpty && isCurrent {
                                Text("Typing here...")
                                    .font(.system(.caption, design: .monospaced))
                                    .italic()
                                    .foregroundColor(.secondary.opacity(0.3))
                            } else {
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.primary.opacity(isCurrent ? 0.8 : 0.4))
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
            .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: RhymeAITokens.Radius.md)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: RhymeAITokens.Spacing.hairline)
            )
        }
    }
}
