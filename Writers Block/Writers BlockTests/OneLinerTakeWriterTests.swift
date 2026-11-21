import AVFoundation
import Foundation
import Testing
@testable import Writers_Block

/// The take writer turns any input format into an AAC file the encoder accepts, with no microphone:
/// synthetic buffers in the hardware's format go in, and the finished file is read back.
struct OneLinerTakeWriterTests {
    /// Writes `seconds` of a 440 Hz tone in `format`, in tap-sized buffers, and reads the file back.
    /// With `liveChannel`, only that input carries the tone and the others are silent.
    private static func record(
        _ format: AVAudioFormat, seconds: Double, liveChannel: Int? = nil
    ) throws -> (channels: AVAudioChannelCount, rate: Double, duration: Double, rms: Float) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("take-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let writer = try OneLinerTakeWriter(url: url, inputFormat: format)
            let chunk: AVAudioFrameCount = 2048
            var written = 0
            let total = Int(format.sampleRate * seconds)
            while written < total {
                let frames = AVAudioFrameCount(min(Int(chunk), total - written))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                let channels = try #require(buffer.floatChannelData)
                for channel in 0..<Int(format.channelCount) {
                    for frame in 0..<Int(frames) {
                        let live = liveChannel.map { $0 == channel } ?? true
                        channels[channel][frame] = live ? 0.5 * sin(2 * .pi * 440 * Double(written + frame) / format.sampleRate).float : 0
                    }
                }
                let out = try writer.write(buffer)
                #expect(out.format.channelCount == writer.outputFormat.channelCount)
                written += Int(frames)
            }
            try writer.finish()
        } // The writer and its file are released here, which closes the file.
        let file = try AVAudioFile(forReading: url)
        let decoded = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: decoded)
        let samples = try #require(decoded.floatChannelData)[0]
        let count = Int(decoded.frameLength)
        let rms = count == 0 ? 0 : (0..<count).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }.squareRoot() / Float(count).squareRoot()
        return (file.fileFormat.channelCount, file.fileFormat.sampleRate, Double(file.length) / file.fileFormat.sampleRate, rms)
    }

    /// A microphone on input 5 of an 18-input interface is the take, at its own level:
    /// a 0.5 tone has an RMS of about 0.35, which neither silence nor an average of 18 inputs reaches.
    @Test func aMicrophoneOnALaterInputOfAMultichannelInterfaceIsHeardAtItsLevel() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 18))
        let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channelLayout: layout)
        let file = try Self.record(format, seconds: 1, liveChannel: 4)
        #expect(file.channels == 1)
        #expect(file.rms > 0.25 && file.rms < 0.45, "rms \(file.rms)")
    }

    @Test func eighteenChannel96kHzInterfaceRecordsMono48kHz() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 18))
        let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channelLayout: layout)
        #expect(format.channelCount == 18)
        let file = try Self.record(format, seconds: 1)
        #expect(file.channels == 1)
        #expect(file.rate == 48_000)
        #expect(abs(file.duration - 1) < 0.1, "duration \(file.duration)")
    }

    @Test func mono48kHzMicrophonePassesStraightThrough() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let output = try #require(OneLinerTakeWriter.outputFormat(for: format))
        #expect(output.sampleRate == 48_000 && output.channelCount == 1)
        let file = try Self.record(format, seconds: 1)
        #expect(file.channels == 1)
        #expect(file.rate == 48_000)
        #expect(abs(file.duration - 1) < 0.1, "duration \(file.duration)")
    }

    @Test func formatRuleKeepsStereoAndStandardRates() throws {
        let stereo441 = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let out = try #require(OneLinerTakeWriter.outputFormat(for: stereo441))
        #expect(out.channelCount == 2 && out.sampleRate == 44_100)
        let stereo192 = try #require(AVAudioFormat(standardFormatWithSampleRate: 192_000, channels: 2))
        let resampled = try #require(OneLinerTakeWriter.outputFormat(for: stereo192))
        #expect(resampled.channelCount == 2 && resampled.sampleRate == 48_000)
    }
}

private extension Double {
    var float: Float { Float(self) }
}
