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
    /// iPad 380 column (332) and the wider iPad column (407) rows, in both appearances. The
    /// one exception is the spec's own copy for a downloaded, unselected E4B on a device under
    /// 10 GB (gallery 11): "Richer lines · 5.34 GB on this device" wraps in a text column under
    /// about 205pt and its warning adds a third line, so that row grows below a 407pt row.
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
                    if index == 11, width < 407 {
                        #expect(size.height > RhymeAITokens.ModelRow.height, "state \(index) at \(width)pt in \(style)")
                    } else {
                        #expect(size.height == RhymeAITokens.ModelRow.height, "state \(index) at \(width)pt in \(style)")
                    }
                }
            }
        }
    }

    /// The download wave sits a φ step (8pt) under the progress copy inside the text column,
    /// well clear of the card's bottom edge, and the title holds still across every state.
    @Test func waveSitsUnderTheMetadataAndTheTitleHoldsStill() async throws {
        let progressStates = [1, 2, 3, 4]  // starting, downloading, paused, checking
        for width in [CGFloat(345), 332, 407] {
            var titleTops: [Int: CGFloat] = [:]
            for (index, sample) in ModelRowContent.gallery.enumerated() {
                let id = "probe-\(Int(width))-\(index)"
                let frames = try await layOut(sample, width: width, identifier: id)
                titleTops[index] = frames["title"]?.minY
                guard progressStates.contains(index) else {
                    #expect(sample.content.line == .none, "state \(index)")
                    continue
                }
                let metadata = try #require(frames["metadata"], "state \(index) at \(width)")
                let wave = try #require(frames["wave"], "state \(index) at \(width)")
                #expect(abs(wave.minY - (metadata.maxY + RhymeAITokens.ModelRow.waveGap)) < 0.5, "state \(index) at \(width): \(wave) under \(metadata)")
                #expect(wave.height == RhymeAITokens.ModelRow.waveHeight)
                #expect(wave.maxY <= RhymeAITokens.ModelRow.height - RhymeAITokens.Rhythm.related, "state \(index) at \(width): \(wave)")
                #expect(abs(wave.minX - RhymeAITokens.Rhythm.standard) < 0.5)
            }
            // The downloaded, unselected E4B under 10 GB (11) grows below 407pt; see above.
            let still = titleTops.filter { $0.key != 11 || width >= 407 }.values
            #expect(still.count >= 15)
            #expect((still.max() ?? 0) - (still.min() ?? 0) < 0.5, "title tops at \(width): \(titleTops)")
        }
    }

    /// One even wave: every crest and trough at the same height, one wavelength apart.
    @Test func theWaveIsEven() {
        let period = RhymeAITokens.ModelRow.wavePeriod
        let height = RhymeAITokens.ModelRow.waveHeight
        let points = ModelRowMotion.evenWavePoints(width: period * 4)
        for crest in 0..<4 {
            let top = CGFloat(crest) * period + period / 4
            let bottom = top + period / 2
            let nearTop = points.min { abs($0.x - top) < abs($1.x - top) }!
            let nearBottom = points.min { abs($0.x - bottom) < abs($1.x - bottom) }!
            #expect(nearTop.y < 0.25, "crest \(crest)")  // sampled every 2pt
            #expect(nearBottom.y > height - 0.25, "trough \(crest)")
        }
        #expect(points.allSatisfy { $0.y >= -0.001 && $0.y <= height + 0.001 })
    }

    /// Lays a row out in a window and returns its parts' frames from the layout probe.
    private func layOut(_ sample: (content: ModelRowContent, isWet: Bool), width: CGFloat, identifier: String) async throws -> [String: CGRect] {
        let host = UIHostingController(rootView:
            ModelRowView(content: sample.content, isWet: sample.isWet, identifier: identifier, columnIdentifier: "column",
                         action: {}, columnAction: {})
                .environment(\.dynamicTypeSize, .large)
                .frame(width: width)
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(10)
        while ModelRowLayoutProbe.frames["\(identifier).title"] == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
            host.view.layoutIfNeeded()
        }
        var frames: [String: CGRect] = [:]
        for part in ["title", "metadata", "wave"] {
            frames[part] = ModelRowLayoutProbe.frames["\(identifier).\(part)"]
        }
        try #require(frames["title"] != nil, "no layout for \(identifier)")
        return frames
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
