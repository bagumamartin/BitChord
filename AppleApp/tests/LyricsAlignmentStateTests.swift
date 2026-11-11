@main
enum LyricsAlignmentStateTests {
    static func main() throws {
        try testRetryIsOfferedForRecoverableOutcomesOnly()
        try testPartialAndCompleteHaveDistinctExplanations()
        try testLocaleCandidatesPreferExactPreferenceThenSortFallbacks()
        try testLocaleCandidatesIncludeDetectedLanguageAlternatives()
        print("lyrics alignment state tests passed")
    }

    private static func testRetryIsOfferedForRecoverableOutcomesOnly() throws {
        try expect(LyricsAlignmentState.noMatch.canRetry, "no-match should offer retry")
        try expect(LyricsAlignmentState.audioUnavailable.canRetry, "audio-unavailable should offer retry")
        try expect(LyricsAlignmentState.failed.canRetry, "failure should offer retry")
        try expect(LyricsAlignmentState.partial.canRetry, "partial alignment should offer retry")
        try expect(LyricsAlignmentState.permissionNeeded.canRetry, "permission can be granted in Settings then retried")
        try expect(!LyricsAlignmentState.idle.canRetry, "idle should not offer retry")
        try expect(!LyricsAlignmentState.analyzing.canRetry, "analysis should not offer duplicate retry")
    }

    private static func testPartialAndCompleteHaveDistinctExplanations() throws {
        try expect(LyricsAlignmentState.partial.message != LyricsAlignmentState.complete.message,
                   "partial alignment must not be described as complete")
        try expect(LyricsAlignmentState.partial.message?.contains("Some lines") == true,
                   "partial status should identify incomplete coverage")
        try expect(LyricsAlignmentState.complete.message?.contains("synced locally") == true,
                   "complete status should identify local sync")
    }

    private static func testLocaleCandidatesPreferExactPreferenceThenSortFallbacks() throws {
        let candidates = LyricsLocaleCandidates.ordered(
            detectedLanguages: ["en"],
            preferredIdentifiers: ["en-US", "fr-FR"],
            supportedIdentifiers: ["en-GB", "fr-FR", "en-US", "en-AU", "ja-JP"]
        )
        try expect(candidates.first == "en-US", "exact preferred locale must be first")
        try expect(candidates.dropFirst().elementsEqual(["fr-FR", "en-AU", "en-GB"]),
                   "remaining matching locales must be deterministic")
        try expect(!candidates.contains("ja-JP"), "unrelated locales must be excluded")
    }

    private static func testLocaleCandidatesIncludeDetectedLanguageAlternatives() throws {
        let candidates = LyricsLocaleCandidates.ordered(
            detectedLanguages: ["es"],
            preferredIdentifiers: ["en-US"],
            supportedIdentifiers: ["en-US", "es-MX", "es-ES", "en-GB"]
        )
        try expect(candidates == ["en-US", "en-GB", "es-ES", "es-MX"],
                   "all detected-language locales should remain available as fallbacks: \(candidates)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
    }
}

private enum CheckFailure: Error { case failed(String) }
