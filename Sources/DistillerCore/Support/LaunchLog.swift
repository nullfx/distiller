import Foundation

/// Writes a launched program's output to its log, keeping the log a readable size however
/// much the program prints. Some games, through Wine and the graphics layers, print the same
/// warning many times a second for hours; one such launch log reached 51 GB.
///
/// The log keeps the first `headLimit` bytes (startup, what troubleshooting needs most) and the
/// last `tailLimit` bytes (how it ended), with a line in between saying how much was left out.
/// The tail is kept in memory until `finish()`.
public final class LaunchLog: @unchecked Sendable {
    public static let defaultHeadLimit = 20 * 1024 * 1024
    public static let defaultTailLimit = 4 * 1024 * 1024

    let headLimit: Int
    let tailLimit: Int
    private let handle: FileHandle
    private let lock = NSLock()
    private var written = 0
    private var skipped = 0
    private var tail = Data()
    private var finished = false

    public init(handle: FileHandle, headLimit: Int = LaunchLog.defaultHeadLimit, tailLimit: Int = LaunchLog.defaultTailLimit) {
        self.handle = handle
        self.headLimit = headLimit
        self.tailLimit = tailLimit
    }

    /// Adds output. After `finish()`, output is accepted and dropped, so the program never
    /// blocks on a full pipe.
    public func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !data.isEmpty else { return }
        var chunk = data
        if written < headLimit {
            let room = headLimit - written
            let head = chunk.prefix(room)
            try? handle.write(contentsOf: head)
            written += head.count
            chunk = chunk.dropFirst(head.count)
        }
        guard !chunk.isEmpty else { return }
        tail.append(chunk)
        // Trim in batches, so a steady trickle doesn't copy the tail on every write.
        if tail.count > tailLimit * 2 {
            let excess = tail.count - tailLimit
            skipped += excess
            tail = Data(tail.suffix(tailLimit))
        }
    }

    /// Writes the kept tail (after a note, if anything was left out) and closes the log.
    public func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if tail.count > tailLimit {
            skipped += tail.count - tailLimit
            tail = Data(tail.suffix(tailLimit))
        }
        if skipped > 0 {
            let note = "\n[Distiller: \(Self.size(skipped)) of output left out here. Launch logs keep the first \(Self.size(headLimit)) and the last \(Self.size(tailLimit)).]\n"
            try? handle.write(contentsOf: Data(note.utf8))
        }
        try? handle.write(contentsOf: tail)
        tail = Data()
        try? handle.close()
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
