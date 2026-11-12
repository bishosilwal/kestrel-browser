// Reports real memory footprint and cumulative CPU time for browsers, attributing
// helper processes the way Activity Monitor does.
//
//   memreport                          Lantern, Google Chrome, Safari
//   memreport Lantern "Google Chrome"  specific apps
//   memreport --json ...               one JSON line per app, for scripting
import Foundation
import Darwin
setvbuf(stdout, nil, _IONBF, 0)

@_silgen_name("responsibility_get_pid_responsible_for_pid")
func respFor(_ pid: pid_t) -> pid_t

struct Usage {
    var footprint: UInt64 = 0
    var cpuNanos: UInt64 = 0
}

/// `proc_pid_rusage` is declared as taking `rusage_info_t *` (i.e. `void **`) but
/// actually wants the address of the struct itself; C callers cast `&rusage`.
func usage(of pid: pid_t) -> Usage {
    let size = MemoryLayout<rusage_info_v4>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    guard proc_pid_rusage(pid, 4, raw.assumingMemoryBound(to: rusage_info_t?.self)) == 0 else { return Usage() }
    let r = raw.load(as: rusage_info_v4.self)
    return Usage(footprint: r.ri_phys_footprint, cpuNanos: r.ri_user_time + r.ri_system_time)
}

/// Parent pid, so helper processes can be attributed by ancestry as well as by the
/// kernel's "responsible process". Chrome spawns renderers from a zygote helper, so
/// the chain has to be walked, not just checked one level up.
func parent(of pid: pid_t) -> pid_t {
    var info = proc_bsdinfo()
    let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return n > 0 ? pid_t(info.pbi_ppid) : 0
}

func path(of pid: pid_t) -> String {
    let b = UnsafeMutablePointer<CChar>.allocate(capacity: 4096); defer { b.deallocate() }
    b[0] = 0
    guard proc_pidpath(pid, b, 4096) > 0 else { return "" }
    return String(cString: b)
}

var args = Array(CommandLine.arguments.dropFirst())
let asJSON = args.contains("--json")
args.removeAll { $0 == "--json" }
let targets = args.isEmpty ? ["Lantern", "Google Chrome", "Safari"] : args

let reported = proc_listallpids(nil, 0)
var pids = [pid_t](repeating: 0, count: Int(reported) * 2 + 64)
_ = proc_listallpids(&pids, Int32(pids.count * 4))
let live = pids.filter { $0 > 0 }.map { (pid: $0, path: path(of: $0)) }

func mb(_ b: UInt64) -> String { String(format: "%8.1f MB", Double(b) / 1_048_576) }
func kind(_ p: String) -> String {
    for k in ["WebContent", "Networking", "GPU", "Helper (Renderer)", "Helper (GPU)",
              "Helper (Plugin)", "Helper", "Safari"] where p.contains(k) { return k }
    return "helper"
}

for target in targets {
    let roots = live.filter { $0.path.contains("/\(target).app/Contents/MacOS/") }.map { $0.pid }
    guard !roots.isEmpty else {
        print(asJSON ? "{\"app\":\"\(target)\",\"running\":false}" : "\(target): not running\n")
        continue
    }
    let rootSet = Set(roots)

    var total = Usage()
    var rows: [(UInt64, String)] = []
    for r in roots {
        let u = usage(of: r)
        total.footprint += u.footprint; total.cpuNanos += u.cpuNanos
        rows.append((u.footprint, "\(target) (pid \(r))"))
    }
    // Helpers: WebKit's shared XPC services, or Chrome-style helpers nested in the
    // app bundle. Accept one if the kernel says this app is responsible for it, or if
    // its parent chain reaches the app -- responsibility alone breaks when a browser is
    // started from a shell rather than through LaunchServices.
    func belongsToApp(_ pid: pid_t) -> Bool {
        if rootSet.contains(respFor(pid)) { return true }
        var cur = parent(of: pid)
        var hops = 0
        while cur > 1 && hops < 8 {
            if rootSet.contains(cur) { return true }
            cur = parent(of: cur)
            hops += 1
        }
        return false
    }
    var helpers = 0
    for proc in live where !rootSet.contains(proc.pid) {
        let inBundle = proc.path.contains("/\(target).app/")
        let isWebKit = proc.path.contains("WebKit.framework") || proc.path.contains("com.apple.WebKit")
        guard inBundle || isWebKit, belongsToApp(proc.pid) else { continue }
        let u = usage(of: proc.pid)
        guard u.footprint > 0 else { continue }
        total.footprint += u.footprint; total.cpuNanos += u.cpuNanos
        helpers += 1
        rows.append((u.footprint, "\u{2514}\u{2500} \(kind(proc.path)) (pid \(proc.pid))"))
    }

    if asJSON {
        print("{\"app\":\"\(target)\",\"running\":true,\"footprint_bytes\":\(total.footprint),"
            + "\"cpu_ns\":\(total.cpuNanos),\"procs\":\(roots.count + helpers)}")
    } else {
        for (f, label) in rows { print("\(mb(f))  \(label)") }
        print(String(repeating: "\u{2500}", count: 52))
        print("\(mb(total.footprint))  \(target): \(roots.count) app + \(helpers) helper"
            + " process\(helpers == 1 ? "" : "es"), "
            + String(format: "%.1f s CPU total", Double(total.cpuNanos) / 1e9) + "\n")
    }
}
