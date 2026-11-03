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
