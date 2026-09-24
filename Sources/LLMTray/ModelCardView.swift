import SwiftUI

struct ModelCardView: View {
    @ObservedObject var browser: HFModelBrowser

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(browser.modelCardID ?? "Model card")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Close") {
                    browser.dismissModelCard()
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    if browser.modelCardLoading {
                        ProgressView().padding(24)
                    } else if let err = browser.modelCardError {
                        Text(err)
                            .foregroundColor(.secondary)
                            .padding(24)
                    } else if let markdown = browser.modelCardMarkdown {
                        Text(renderedMarkdown(markdown))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
        }
        .frame(width: 560, height: 480)
    }

    /// Headings, lists, quotes, code blocks and inline formatting via the
    /// same renderer the chat bubbles use (ChatMarkdown) -- the previous
    /// inline-only AttributedString parse left "## Usage" and list markers
    /// as raw text. Tables and HTML still come through as plain text.
    private func renderedMarkdown(_ text: String) -> AttributedString {
        ChatMarkdown.render(text, baseSize: 12)
    }
}
