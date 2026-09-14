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

    /// Basic GFM support (headers, bold/italic, links, lists) via
    /// AttributedString's built-in Markdown parser -- not a full renderer
    /// (tables, images, HTML blocks fall back to plain text), but enough to
    /// make a model card readable rather than showing raw "## Usage" markup.
    private func renderedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
