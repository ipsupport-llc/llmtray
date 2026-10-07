import SwiftUI

/// What a model's answers are, and aren't: a card on the welcome page and
/// in About; one line under the chat's message field (the card's text on
/// hover).
enum ModelDisclaimer {
    static var title: Text { Text("A model is a tool, not an authority") }
    static var body: Text { Text("It can be wrong and make things up: check anything that matters. It is not a doctor, lawyer, psychologist or friend. You use its answers at your own risk.") }
    static var help: String {
        NSLocalizedString("A model is a tool, not an authority", comment: "") + "\n"
            + NSLocalizedString("It can be wrong and make things up: check anything that matters. It is not a doctor, lawyer, psychologist or friend. You use its answers at your own risk.", comment: "")
    }

    struct Card: View {
        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.bubble")
                    .font(.title3)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    ModelDisclaimer.title.font(.callout.weight(.semibold))
                    ModelDisclaimer.body
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.orange.opacity(0.25)))
            .accessibilityElement(children: .combine)
        }
    }

    struct Line: View {
        var body: some View {
            Text("Models can make mistakes. Check important information.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .help(ModelDisclaimer.help)
        }
    }
}
