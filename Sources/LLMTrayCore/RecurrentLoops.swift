import Foundation

/// A looped model's (NVIDIA Dory's) loop count per request: the server's
/// default is the profile's (Settings > Profiles > Loops, at launch); the
/// composer's pick, sent as recurrent_loops, overrides it per request.
public enum RecurrentLoops {
    /// The request's recurrent_loops, nil: the server's own. `modelLoops`:
    /// the model's config count, nil for a model that isn't looped;
    /// `picked`: 0 = default, else 1-4. A voice conversation gets no
    /// shortcut: with one loop Dory 1.0 didn't finish its thinking in 1200
    /// tokens on any of four test questions.
    public static func requestValue(modelLoops: Int?, picked: Int) -> Int? {
        guard modelLoops != nil else { return nil }
        return (1...4).contains(picked) ? picked : nil
    }
}
