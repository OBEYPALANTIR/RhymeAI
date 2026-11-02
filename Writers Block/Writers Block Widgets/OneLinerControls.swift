import AppIntents
import SwiftUI
import WidgetKit

/// Control Center, the Lock Screen and the Action button: opens Writers Block already recording.
struct OneLinerRecordControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ShaydeTree.Writers-Block.OneLinerRecordControl") {
            ControlWidgetButton(action: RecordOneLinerIntent()) {
                Label("Record", systemImage: "mic")
            }
        }
        .displayName("Record One Liner")
        .description("Opens Writers Block already recording.")
    }
}

/// Opens the capture sheet with the keyboard up.
struct OneLinerTypeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "ShaydeTree.Writers-Block.OneLinerTypeControl") {
            ControlWidgetButton(action: OpenCaptureIntent(mode: .type)) {
                Label("Type", systemImage: "keyboard")
            }
        }
        .displayName("Type One Liner")
        .description("Opens Writers Block ready to type a line.")
    }
}
