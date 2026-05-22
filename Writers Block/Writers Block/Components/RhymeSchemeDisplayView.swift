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
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rhymeContext.stanzaLines.enumerated()), id: \.offset) { index, line in
                        let letter = String(schemeLetters[index % schemeLetters.count])
                        let isCurrent = index == rhymeContext.currentLineIndex

                        HStack(spacing: 12) {
                            Text(letter)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(isCurrent ? .indigo : .secondary.opacity(0.4))
                                .frame(width: 16, alignment: .leading)

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
                        .padding(.vertical, 1)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 160)
            .background(Color(UIColor.secondarySystemBackground).opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }
}
