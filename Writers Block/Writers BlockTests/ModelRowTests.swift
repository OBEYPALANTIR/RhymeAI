import SwiftUI
import Testing
import UIKit
@testable import Writers_Block

/// Settings › On-Device model rows: copy per state, the delete confirmation, one height for
/// every state, and the Reduce Motion fallbacks.
@MainActor
struct ModelRowTests {
    private let e2b = GGUFDownloadCatalog.options[0]
    private let e4b = GGUFDownloadCatalog.options[1]
    private typealias Facts = ModelRowContent.Facts

    @Test func inUseSentenceOnlyWhenTheModelIsSelected() {
        let sentence = " It's in use now; on-device suggestions stop until you choose another model."
        #expect(ModelRowContent.deleteMessage(bytes: 3_427_880_800, isCustom: false, inUse: false)
                == "Frees 3.43 GB on this device. You can download it again later.")
        #expect(ModelRowContent.deleteMessage(bytes: 3_427_880_800, isCustom: false, inUse: true)
                == "Frees 3.43 GB on this device. You can download it again later." + sentence)
        #expect(ModelRowContent.deleteMessage(bytes: 812_000_000, isCustom: true, inUse: false)
                == "Frees 812 MB on this device. You can import it again later.")
        #expect(ModelRowContent.deleteMessage(bytes: 812_000_000, isCustom: true, inUse: true).hasSuffix(sentence))
    }

    @Test func progressNamesTheUnitOnce() {
        #expect(ModelRowContent.progress(1_474_000_000, of: 3_427_880_800) == "1.47 of 3.43 GB")
        #expect(ModelRowContent.progress(512_000_000, of: 3_427_880_800) == "512 MB of 3.43 GB")
    }

    /// The build spec's state table, row by row.
    @Test func everyStateReadsAsTheSpecWrites() {
        let installed = Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true)
        let cases: [(ModelRowContent, String, String?, ModelRowContent.Chip?, ModelRowContent.Column, ModelRowContent.Line)] = [
            (.catalog(e2b, facts: Facts()), "Quick drafts · 3.43 GB · Recommended", nil, .download, .empty, .none),
            (.catalog(e4b, facts: Facts()), "Richer lines · 5.34 GB", nil, .download, .empty, .none),
            (.catalog(e2b, facts: Facts(isActive: true)), "Starting download…", nil, .pause, .cancel, .ghost),
            (.catalog(e2b, facts: Facts(isActive: true, receivedBytes: 1_474_000_000)), "1.47 of 3.43 GB · 43%", nil, .pause, .cancel,
             .written(Double(1_474_000_000) / Double(e2b.expectedBytes))),
            (.catalog(e2b, facts: Facts(pausedBytes: 1_474_000_000)), "Paused · 1.47 of 3.43 GB", nil, .resume, .cancel,
             .written(Double(1_474_000_000) / Double(e2b.expectedBytes))),
            (.catalog(e2b, facts: Facts(isActive: true, isVerifying: true)), "Checking the file…", nil, nil, .empty, .written(1)),
            (.catalog(e2b, facts: installed), "Quick drafts · 3.43 GB on this device", nil, .use, .trash, .none),
            (.catalog(e2b, facts: Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true, isSelected: true)),
             "In use · 3.43 GB on this device", nil, .selected, .trash, .none),
            (.catalog(e2b, facts: Facts(bytesOnDisk: 3_427_878_784)), "Older version on this device", nil, .update, .trash, .none),
            (.catalog(e4b, facts: Facts(needsMoreMemory: true)), "Richer lines · 5.34 GB", "Writes slowly: needs 10 GB", .download, .empty, .none),
            (.catalog(e4b, facts: Facts(bytesOnDisk: e4b.expectedBytes, isInstalled: true, needsMoreMemory: true)),
             "Richer lines · 5.34 GB on this device", "Writes slowly: needs 10 GB", .use, .trash, .none),
            (.catalog(e2b, facts: Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true, isDeleting: true)), "Deleting…", nil, nil, .spinner, .none),
            (.catalog(e2b, facts: Facts(freedBytes: e2b.expectedBytes)), "3.43 GB back for your songs", nil, .download, .empty, .none),
        ]
        for (row, metadata, warning, chip, column, line) in cases {
            #expect(row.metadata == metadata)
            #expect(row.warning == warning, "\(metadata)")
            #expect(row.chip == chip, "\(metadata)")
            #expect(row.column == column, "\(metadata)")
            #expect(row.line == line, "\(metadata)")
        }
        let deleting = ModelRowContent.catalog(e2b, facts: Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true, isDeleting: true))
        #expect(deleting.strike && !deleting.isEnabled)
        #expect(!ModelRowContent.catalog(e2b, facts: Facts(isActive: true, isVerifying: true)).isEnabled)
        #expect(ModelRowContent.catalog(e2b, facts: Facts(bytesOnDisk: 1, isInstalled: false)).metadataIsWarning)
        #expect(ModelRowContent.catalog(e4b, facts: Facts(needsMoreMemory: true)).accessibilityValue
                == "Richer lines, 5.34 GB, Writes slowly, needs 10 GB memory")
        #expect(ModelRowContent.catalog(e2b, facts: Facts()).accessibilityLabel == "Download RhymeAI Gemma 4 E2B")
    }

    /// No state changes the row's size: every state is 89pt tall at the iPhone (345), the
    /// iPad 380 column (332) and the wider iPad column (407) rows, in both appearances.
    @Test func rowHeightIsConstantAcrossStates() {
        for style in [AppAppearanceStyle.ink, .graphite] {
            for width in [CGFloat(345), 332, 407] {
                for (index, sample) in ModelRowContent.gallery.enumerated() {
                    let host = UIHostingController(rootView:
                        ModelRowView(content: sample.content, isWet: sample.isWet, identifier: "row", columnIdentifier: "column",
                                     action: {}, columnAction: {})
                            .environment(\.appAppearanceStyle, style)
                            .environment(\.dynamicTypeSize, .large)
                    )
                    let size = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                    #expect(size.height == RhymeAITokens.ModelRow.height, "state \(index) at \(width)pt in \(style)")
                }
            }
        }
    }

    /// Reduce Motion: the ghost holds its still frame, Select goes straight to the dry chip
    /// and the strike appears whole; with motion the ghost loops like the suggestion ghost.
    @Test func reduceMotionFallbacks() {
        for elapsed in [0, 0.4, 1.1, 2.0, 7.3] {
            #expect(ModelRowMotion.ghostProgress(elapsed: elapsed, reduceMotion: true) == 0.6)
        }
        #expect(!ModelRowMotion.beginsWet(reduceMotion: true))
        #expect(ModelRowMotion.strikeStart(reduceMotion: true) == 1)

        #expect(ModelRowMotion.ghostProgress(elapsed: 0, reduceMotion: false) == 0)
        #expect(abs(ModelRowMotion.ghostProgress(elapsed: 0.65, reduceMotion: false) - 0.5) < 0.0001)
        #expect(ModelRowMotion.ghostProgress(elapsed: 1.5, reduceMotion: false) == 1)  // the hold
        #expect(ModelRowMotion.ghostProgress(elapsed: SuggestionInkLineMotion.loopPeriod + 0.0001, reduceMotion: false) < 0.01)  // wiped
        #expect(ModelRowMotion.beginsWet(reduceMotion: false))
        #expect(ModelRowMotion.strikeStart(reduceMotion: false) == 0)
        #expect(ModelRowMotion.wetHold == 2.0)
    }
}
