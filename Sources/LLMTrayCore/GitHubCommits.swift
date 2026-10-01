import Foundation

/// Whether a fork branch's tip is a newer commit than the one in use: the
/// runtime updates (mlx-lm, mlx-audio) offer it only then. A tip that
/// merely differs isn't an update: a branch left behind (the mlx-lm fork's
/// `beta` sat 45 commits behind `main`) would otherwise be offered, and
/// installed, as one -- a downgrade.
public enum GitHubCommits {
    /// GitHub's compare status of `base...head`: "ahead" means head has
    /// commits base lacks and none the other way.
    public static func isNewer(compareStatus status: String) -> Bool {
        status == "ahead"
    }

    /// `head` is ahead of `base` in `repo` ("org/name"), by GitHub's compare
    /// API. Throws offline or on an unexpected answer.
    public static func isNewer(_ head: String, than base: String, in repo: String,
                               session: URLSession = .shared) async throws -> Bool {
        let url = URL(string: "https://api.github.com/repos/\(repo)/compare/\(base)...\(head)")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: request)
        guard let status = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return isNewer(compareStatus: status)
    }
}
