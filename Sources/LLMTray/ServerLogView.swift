import SwiftUI

extension Notification.Name {
    static let showServerLog = Notification.Name("LLMTray.showServerLog")
}

struct ServerLogView: View {
    @ObservedObject var server: ServerManager

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(server.log.isEmpty ? "(no server output yet)" : server.log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .id("bottom")
            }
            .onChange(of: server.log) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .frame(minWidth: 600, minHeight: 360)
    }
}
