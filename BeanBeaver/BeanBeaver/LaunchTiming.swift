import Foundation
import Darwin

/// Headless launch-latency probe for the real-device Debug-vs-Release comparison.
/// Inert unless the app is launched with `-logLaunchTiming`, so it has zero cost
/// in a normal build.
///
/// It measures **process creation → first frame**: the kernel records when the
/// process was forked/exec'd (before `main()`), so the delta captures the whole
/// pre-`main()` window — dyld mapping + code-signature validation + C++ static
/// initializers of the statically-linked ONNX runtime — which is exactly the
/// span the (previously blank) launch screen is on screen.
///
/// Each launch appends one record to `Documents/launch_timing.json`; a host
/// script pulls it via `devicectl device copy from` (mirroring `BatchRunner`'s
/// `batch_out.json`) and reports the distribution across cold launches.
enum LaunchTiming {
    static let isRequested = ProcessInfo.processInfo.arguments.contains("-logLaunchTiming")

    /// Build configuration this binary was compiled in, so pulled records are
    /// self-labeling regardless of which file the host writes them to.
    static var configuration: String {
#if DEBUG
        "debug"
#else
        "release"
#endif
    }

    /// Seconds from process creation (fork/exec) to now, from the kernel's
    /// recorded `p_starttime`. Same wall clock as `Date()`, so the subtraction is
    /// valid over the few-second launch window.
    static func secondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_starttime
        let startEpoch = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - startEpoch
    }

    /// Record one first-frame measurement. Safe to call unconditionally: no-ops
    /// unless `-logLaunchTiming` was passed.
    static func recordFirstFrame() {
        guard isRequested, let elapsed = secondsSinceProcessStart() else { return }
        let ms = (elapsed * 1000).rounded()
        NSLog("[LaunchTiming] config=\(configuration) firstFrame=\(Int(ms))ms sinceProcStart")

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("launch_timing.json")
        var records = ((try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]]) ?? []
        records.append([
            "config": configuration,
            "ms": ms,
            "at": Date().timeIntervalSince1970,
        ])
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
