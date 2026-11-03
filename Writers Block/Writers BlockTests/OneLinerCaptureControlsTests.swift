import Testing
@testable import Writers_Block

@MainActor
struct OneLinerCaptureControlsTests {
    @Test
    func aStoppedTakeShowsItsRowInsteadOfTheMic() {
        let controls = OneLinerCaptureControls(isEdit: false, microphoneBusy: false, isRecording: false, hasTake: true)
        #expect(controls.takeRow)
        #expect(!controls.record)
    }

    @Test
    func noTakeYetOffersTheMicAndNoRow() {
        let controls = OneLinerCaptureControls(isEdit: false, microphoneBusy: false, isRecording: false, hasTake: false)
        #expect(!controls.takeRow)
        #expect(controls.record)
    }

    @Test
    func recordingShowsNeitherTheRowNorTheMic() {
        // The recording row and Stop take their place.
        let controls = OneLinerCaptureControls(isEdit: false, microphoneBusy: false, isRecording: true, hasTake: true)
        #expect(!controls.takeRow)
        #expect(!controls.record)
    }

    @Test
    func editNeverRecordsOrShowsATake() {
        for hasTake in [false, true] {
            let controls = OneLinerCaptureControls(isEdit: true, microphoneBusy: false, isRecording: false, hasTake: hasTake)
            #expect(!controls.takeRow)
            #expect(!controls.record)
        }
    }

    @Test
    func aBusyMicrophoneHidesTheMicButKeepsATakesRow() {
        #expect(!OneLinerCaptureControls(isEdit: false, microphoneBusy: true, isRecording: false, hasTake: false).record)
        #expect(OneLinerCaptureControls(isEdit: false, microphoneBusy: true, isRecording: false, hasTake: true).takeRow)
    }
}

/// Which take a late speech result belongs to, through the recorder's own
/// bookkeeping (the same calls `start`, `stop` and `discard` make; no microphone).
@MainActor
struct OneLinerTakeOwnershipTests {
    @Test
    func aDiscardedTakesLateWordsNeverReachTheNextTake() {
        let recorder = OneLinerRecorder()
        let first = recorder.beginTake()
        recorder.receive(transcript: "Found the Lord", forTake: first)
        recorder.discard()
        let second = recorder.beginTake()

        recorder.receive(transcript: "Found the Lord in a gas station", forTake: first)

        #expect(recorder.transcript == OneLinerTranscript(take: second, text: ""))
    }

    @Test
    func theSameWordsOnANewTakeStillReadAsAChange() {
        let recorder = OneLinerRecorder()
        let first = recorder.beginTake()
        recorder.receive(transcript: "Half a heart", forTake: first)
        let heardFirst = recorder.transcript
        recorder.discard()
        let second = recorder.beginTake()

        recorder.receive(transcript: "Half a heart", forTake: second)

        #expect(recorder.transcript.text == "Half a heart")
        #expect(recorder.transcript != heardFirst, "The capture's onChange fires again for the new take")
        // And the field puts the new take's words after the ones the writer kept.
        #expect(OneLinerCaptureView.fieldText(current: "Half a heart", lastTranscribed: "Half a heart", beforeTake: "Half a heart", transcript: "Half a heart") == "Half a heart Half a heart")
    }

    @Test
    func aStoppedTakesFinalWordsStillLand() {
        let recorder = OneLinerRecorder()
        let take = recorder.beginTake()
        recorder.receive(transcript: "Half a", forTake: take)
        recorder.stop()

        recorder.receive(transcript: "Half a heart still beats", forTake: take)

        #expect(recorder.transcript == OneLinerTranscript(take: take, text: "Half a heart still beats"))
    }

    @Test
    func aSupersededTakesWordsAreDropped() {
        let recorder = OneLinerRecorder()
        let first = recorder.beginTake()
        recorder.stop()
        let second = recorder.beginTake()

        recorder.receive(transcript: "from the first take", forTake: first)

        #expect(recorder.transcript == OneLinerTranscript(take: second, text: ""))
    }
}

@MainActor
struct OneLinerCaptureFieldTextTests {
    @Test
    func theTranscriptFollowsTheWordsFromBeforeTheTake() {
        #expect(OneLinerCaptureView.fieldText(current: "", lastTranscribed: "", beforeTake: "", transcript: "Half a") == "Half a")
        #expect(OneLinerCaptureView.fieldText(current: "Half a", lastTranscribed: "Half a", beforeTake: "", transcript: "Half a heart") == "Half a heart")
        #expect(OneLinerCaptureView.fieldText(current: "Gas station", lastTranscribed: "Gas station", beforeTake: "Gas station", transcript: "bathroom") == "Gas station bathroom")
    }

    @Test
    func anEditDuringTheTakeWins() {
        #expect(OneLinerCaptureView.fieldText(current: "Half a hart, fixed", lastTranscribed: "Half a hart", beforeTake: "", transcript: "Half a hart still") == nil)
    }

    @Test
    func noWordsLeaveTheFieldAlone() {
        #expect(OneLinerCaptureView.fieldText(current: "Kept", lastTranscribed: "Kept", beforeTake: "Kept", transcript: "") == nil)
    }
}
