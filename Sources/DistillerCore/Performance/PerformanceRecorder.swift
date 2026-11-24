import Foundation

/// What a recorded stretch of play measured, from every frame's present interval. The lows
/// are the average frame rate of the slowest 1% and 0.1% of frames.
public struct PerformanceSummary: Codable, Equatable, Sendable {
    /// The frame rates the frame-time buckets stop at; the last bucket is everything slower.
    public static let bucketFPS: [Double] = [120, 90, 60, 50, 40, 30, 20]
    /// Upper edges (ms) of the buckets, with 1% to spare: the HUD rounds to hundredths, so a
    /// frame held to 30 fps by vsync reads 33.34 ms, not 33.33.
    public static let bucketEdgesMs: [Double] = bucketFPS.map { 1000 / $0 * 1.01 }

    public var seconds: Double
    public var frames: Int
    public var fpsAverage: Double
    public var fps1PercentLow: Double
    public var fps01PercentLow: Double
    public var frameMsMedian: Double
    public var frameMsP95: Double
    public var gpuMsMedian: Double?
    /// Percent of frames in each bucket (`bucketEdgesMs`, then slower), one decimal.
    public var histogram: [Double]
    /// Frames per second for each minute recorded (a last part-minute of 10 s or more counts).
    public var timelineFPS: [Double]

    enum CodingKeys: String, CodingKey {
        case seconds, frames, histogram
        case fpsAverage = "fps_avg"
        case fps1PercentLow = "fps_1pct_low"
        case fps01PercentLow = "fps_01pct_low"
        case frameMsMedian = "frame_ms_p50"
        case frameMsP95 = "frame_ms_p95"
        case gpuMsMedian = "gpu_ms_p50"
        case timelineFPS = "timeline_fps"
    }

    /// nil without frames.
    public init?(intervals: [Double], gpuTimes: [Double] = []) {
        guard !intervals.isEmpty else { return nil }
        let total = intervals.reduce(0, +)
        guard total > 0 else { return nil }
        let sorted = intervals.sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double {
            values[min(values.count - 1, Int((Double(values.count - 1) * p).rounded()))]
        }
        func low(_ share: Double) -> Double {
            let count = max(1, Int(Double(sorted.count) * share))
            let slowest = sorted.suffix(count)
            return Self.round(1000 / (slowest.reduce(0, +) / Double(slowest.count)))
        }
        seconds = Self.round(total / 1000)
        frames = intervals.count
        fpsAverage = Self.round(Double(intervals.count) / (total / 1000))
        fps1PercentLow = low(0.01)
        fps01PercentLow = low(0.001)
        frameMsMedian = Self.round(percentile(sorted, 0.5), places: 2)
        frameMsP95 = Self.round(percentile(sorted, 0.95), places: 2)
        gpuMsMedian = gpuTimes.isEmpty ? nil : Self.round(percentile(gpuTimes.sorted(), 0.5), places: 2)

        var counts = [Int](repeating: 0, count: Self.bucketEdgesMs.count + 1)
        for interval in intervals {
            counts[Self.bucketEdgesMs.firstIndex { interval <= $0 } ?? Self.bucketEdgesMs.count] += 1
        }
        histogram = counts.map { Self.round(Double($0) * 100 / Double(intervals.count)) }

        var timeline: [Double] = []
        var elapsed = 0.0
        var count = 0
        for interval in intervals {
            elapsed += interval
            count += 1
            if elapsed >= 60_000 {
                timeline.append(Self.round(Double(count) / (elapsed / 1000)))
                elapsed = 0
                count = 0
            }
        }
        if elapsed >= 10_000 { timeline.append(Self.round(Double(count) / (elapsed / 1000))) }
        timelineFPS = timeline
    }

    static func round(_ value: Double, places: Double = 1) -> Double {
        let factor = pow(10, places)
        return (value * factor).rounded() / factor
    }
}

/// Collects frames from a measured launch (`FrameLogStream`): what's being drawn now, and,
/// between `start` and `stop`, every frame for the summary. Frames from several processes are
/// kept apart; the game is the process that drew the most. Thread-safe (frames arrive on the
/// output reader's thread).
public final class PerformanceRecorder: @unchecked Sendable {
    /// The latest second or so of frames.
    public struct Live: Equatable, Sendable {
        public var fps: Double?
        public var pid: Int?
        /// When the last frames arrived.
        public var lastFrames: Date?
        public var isRecording: Bool
        /// Seconds and frames recorded so far.
        public var recordedSeconds: Double
        public var recordedFrames: Int
    }

    private struct Recording {
        var intervals: [Double] = []
        var gpuTimes: [Double] = []
        var totalMs = 0.0
    }

    private let lock = NSLock()
    private var recording: [Int: Recording]?
    private var recent: [(date: Date, batch: FrameBatch)] = []
    private var lastFrames: Date?
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// A stream that feeds this recorder.
    public func stream() -> FrameLogStream {
        FrameLogStream { [weak self] batch in self?.add(batch) }
    }

    public func add(_ batch: FrameBatch) {
        guard !batch.intervals.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let date = now()
        lastFrames = date
        recent.append((date, batch))
        recent.removeAll { date.timeIntervalSince($0.date) > 3 }
        if recording != nil {
            let key = batch.pid ?? 0
            recording![key, default: Recording()].intervals += batch.intervals
            recording![key, default: Recording()].gpuTimes += batch.gpuTimes
            recording![key, default: Recording()].totalMs += batch.intervals.reduce(0, +)
        }
    }

    public func start() {
        lock.lock()
        recording = [:]
        lock.unlock()
    }

    /// Stops recording; the summary of the game's frames, or nil if none arrived.
    @discardableResult
    public func stop() -> PerformanceSummary? {
        lock.lock()
        defer { lock.unlock() }
        let game = recording?.values.max { $0.intervals.count < $1.intervals.count }
        recording = nil
        return game.flatMap { PerformanceSummary(intervals: $0.intervals, gpuTimes: $0.gpuTimes) }
    }

    public var live: Live {
        lock.lock()
        defer { lock.unlock() }
        let date = now()
        let latest = recent.filter { date.timeIntervalSince($0.date) <= 2.5 }
        var byProcess: [Int: (frames: Int, ms: Double)] = [:]
        for (_, batch) in latest {
            byProcess[batch.pid ?? 0, default: (0, 0)].frames += batch.intervals.count
            byProcess[batch.pid ?? 0, default: (0, 0)].ms += batch.intervals.reduce(0, +)
        }
        let game = byProcess.max { $0.value.frames < $1.value.frames }
        let fps = game.flatMap { $0.value.ms > 0 ? PerformanceSummary.round(Double($0.value.frames) / ($0.value.ms / 1000)) : nil }
        let recorded = recording?.values.max { $0.intervals.count < $1.intervals.count }
        return Live(
            fps: fps, pid: game.map(\.key), lastFrames: lastFrames, isRecording: recording != nil,
            recordedSeconds: (recorded?.totalMs ?? 0) / 1000,
            recordedFrames: recorded?.intervals.count ?? 0
        )
    }
}
