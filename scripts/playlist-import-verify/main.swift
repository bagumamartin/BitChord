import Foundation

@main
enum PlaylistImportChecks {
    static func main() async throws {
        FileHandle.standardError.write(Data("checking CSV\n".utf8))
        try checkCSVQuotesAndBOM()
        FileHandle.standardError.write(Data("checking TSV\n".utf8))
        try checkTSV()
        FileHandle.standardError.write(Data("checking row limit\n".utf8))
        try checkTrackLimit()
        try checkCanceledResultsAreRejected()
        FileHandle.standardError.write(Data("checking cancellation\n".utf8))
        try await checkCancellationStopsScheduling()
        print("Playlist import checks passed")
    }

    private static func checkCSVQuotesAndBOM() throws {
        let csv = "\u{FEFF}Title,Artist,Album\r\n\"Hello, \"\"World\"\"\",Artist,\"A, B\"\r\n"
        let draft = try PlaylistFileImport.parse(data: Data(csv.utf8), filename: "quoted.csv")
        precondition(draft.rows.count == 1)
        precondition(draft.rows[0].title == "Hello, \"World\"")
        precondition(draft.rows[0].album == "A, B")
    }

    private static func checkTSV() throws {
        let tsv = "Track Name\tArtist Name\tDuration\nSong One\tArtist One\t03:21\n"
        let draft = try PlaylistFileImport.parse(data: Data(tsv.utf8), filename: "list.tsv")
        precondition(draft.rows.count == 1)
        precondition(draft.rows[0].title == "Song One")
        precondition(draft.rows[0].artist == "Artist One")
        precondition(draft.rows[0].durationText == "03:21")
    }

    private static func checkTrackLimit() throws {
        let rows = (0..<501).map { "Song \($0),Artist" }.joined(separator: "\n")
        let data = Data(("Title,Artist\n" + rows + "\n").utf8)
        let accepted = try PlaylistFileImport.parse(
            data: Data(("Title,Artist\n" + rows.split(separator: "\n").prefix(500).joined(separator: "\n") + "\n").utf8),
            filename: "five-hundred.csv"
        )
        precondition(accepted.rows.count == 500)
        do {
            _ = try PlaylistFileImport.parse(data: data, filename: "five-hundred-one.csv")
            preconditionFailure("501 tracks must produce an explicit limit error")
        } catch PlaylistFileImport.ImportError.tooManyTracks(let count) {
            precondition(count == 501)
        }
    }

    private static func checkCanceledResultsAreRejected() throws {
        let active = UUID()
        let stale = UUID()
        precondition(!PlaylistFileImport.mayPresentResult(
            requestID: active, activeRequestID: active, isCancelled: true
        ))
        precondition(!PlaylistFileImport.mayPresentResult(
            requestID: stale, activeRequestID: active, isCancelled: false
        ))
        precondition(PlaylistFileImport.mayPresentResult(
            requestID: active, activeRequestID: active, isCancelled: false
        ))
    }

    private static func checkCancellationStopsScheduling() async throws {
        let starts = StartCounter()
        let work = Task {
            await PlaylistFileImport.mapWithBoundedConcurrency(Array(0..<100), limit: 4) { value in
                await starts.increment()
                try? await Task.sleep(for: .seconds(10))
                return value
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        work.cancel()
        _ = await work.value
        let started = await starts.value
        precondition(started > 0 && started <= 4, "Cancellation scheduled \(started) operations")
    }
}

actor StartCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
