import ArgumentParser
import DistillerCore
import Foundation

struct PerformanceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "performance",
        abstract: "Recorded frame rates: summarise a measured launch's log, or list a game's recordings.",
        subcommands: [Summary.self, List.self]
    )

    struct Summary: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Summarise the frame timings in a launch log (from 'distiller launch <game> --measure', or the app's Record Performance)."
        )

        @Argument(help: "The launch log, from Distiller's Logs folder.")
        var log: String

        func run() throws {
            let recorder = PerformanceRecorder()
            recorder.start()
            let stream = recorder.stream()
            let url = URL(fileURLWithPath: (log as NSString).expandingTildeInPath)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                stream.append(chunk)
            }
            stream.append(Data("\n".utf8))
            guard let summary = recorder.stop() else {
                throw ValidationError("No frame timings in \(url.lastPathComponent). They're only there when the game was started measured and drew with Metal.")
            }
            print(LaunchCommand.describe(summary))
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a game's saved recordings, newest first.")

        @Argument(help: "The game ID, from 'distiller games'.")
        var game: String

        func run() throws {
            let engine = try makeEngine()
            let entry = try findGame(game, in: engine)
            let records = engine.performanceRecords(for: entry.id)
            if records.isEmpty {
                print("No recordings for \(entry.title) yet.")
                return
            }
            for record in records {
                let summary = record.summary
                var parts = ["\(record.recordedAt.formatted(date: .abbreviated, time: .shortened))",
                             "\(Int(summary.seconds.rounded())) s",
                             "avg \(summary.fpsAverage) fps", "1% low \(summary.fps1PercentLow)"]
                if let detail = record.settings.detail { parts.append(detail.displayName) }
                if let window = record.display?.window { parts.append(window) }
                if let hz = record.display?.refreshHz { parts.append("\(hz) Hz") }
                print(parts.joined(separator: " · "))
            }
        }
    }
}
