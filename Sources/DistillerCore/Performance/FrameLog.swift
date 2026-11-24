import Foundation

/// One line of Apple's Metal performance HUD log (`MeasuredLaunch`): about a second of frames
/// from one process. The HUD writes `metal-HUD: <first frame>,<a>,<b>` and then, for each
/// frame, its present interval and GPU time in milliseconds. `a` and `b` look like GPU and
/// process memory in megabytes; they're kept but not relied on. On standard error each line
/// starts with the process name and `[pid:thread]`, which tells processes apart.
public struct FrameBatch: Equatable, Sendable {
    public var pid: Int?
    public var firstFrame: Int
    public var summary: (a: Double, b: Double)
    /// Each frame's present interval (the time since the previous frame was shown), in ms.
    public var intervals: [Double]
    /// Each frame's GPU time, in ms.
    public var gpuTimes: [Double]

    public static func == (lhs: FrameBatch, rhs: FrameBatch) -> Bool {
        lhs.pid == rhs.pid && lhs.firstFrame == rhs.firstFrame && lhs.summary == rhs.summary
            && lhs.intervals == rhs.intervals && lhs.gpuTimes == rhs.gpuTimes
    }
}

public enum FrameLog {
    static let marker = "metal-HUD:"
    /// Present intervals above this are pauses (a debugger, a suspended Mac), not frames.
    static let longestFrameMs = 60_000.0

    /// Reads one log line; nil for anything else (including other `metal-HUD` messages).
    public static func parse(_ line: Substring) -> FrameBatch? {
        guard let marker = line.range(of: marker) else { return nil }
        let numbers = line[marker.upperBound...].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard numbers.count >= 3, let first = Int(numbers[0]), let a = Double(numbers[1]), let b = Double(numbers[2]) else {
            return nil
        }
        var intervals: [Double] = []
        var gpu: [Double] = []
        var index = 3
        while index + 1 < numbers.count {
            guard let interval = Double(numbers[index]), let time = Double(numbers[index + 1]),
                  interval.isFinite, time.isFinite, interval >= 0, time >= 0 else { return nil }
            if interval > 0, interval <= longestFrameMs {
                intervals.append(interval)
                gpu.append(time)
            }
            index += 2
        }
        return FrameBatch(pid: pid(in: line[..<marker.lowerBound]), firstFrame: first, summary: (a, b),
                          intervals: intervals, gpuTimes: gpu)
    }

    /// The PID in a standard-error prefix such as `2026-11-24 13:33:43.179 wine[32287:21025373] `.
    static func pid(in prefix: Substring) -> Int? {
        guard let close = prefix.lastIndex(of: "]"), let open = prefix[..<close].lastIndex(of: "[") else { return nil }
        let inside = prefix[prefix.index(after: open)..<close]
        return Int(inside.split(separator: ":").first ?? "")
    }
}

/// Turns a game's output, as it arrives in chunks, into frame batches. Lines can be split
/// across chunks; a line longer than `maxLine` (not a HUD line) is skipped. Thread-safe.
public final class FrameLogStream: @unchecked Sendable {
    static let maxLine = 256 * 1024
    private let lock = NSLock()
    private var pending = Data()
    private var skipping = false
    private let handler: @Sendable (FrameBatch) -> Void

    public init(handler: @escaping @Sendable (FrameBatch) -> Void) {
        self.handler = handler
    }

    public func append(_ chunk: Data) {
        var batches: [FrameBatch] = []
        lock.lock()
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if skipping { skipping = false; continue }
            if let text = String(data: line, encoding: .utf8), text.contains(FrameLog.marker),
               let batch = FrameLog.parse(Substring(text)) {
                batches.append(batch)
            }
        }
        if pending.count > Self.maxLine {
            pending.removeAll(keepingCapacity: false)
            skipping = true
        }
        lock.unlock()
        batches.forEach(handler)
    }
}
