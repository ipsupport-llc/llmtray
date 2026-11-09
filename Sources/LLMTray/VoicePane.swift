import LLMTrayCore
import SwiftUI

/// Settings > Voice (adr/0016, adr/0031): spoken answers and the voice
/// conversation with the chat model.
struct VoicePane: View {
    var body: some View {
        Form {
            SpokenAnswersSection()
            VoiceConversationSection()
        }
        .formStyle(.grouped)
    }
}
