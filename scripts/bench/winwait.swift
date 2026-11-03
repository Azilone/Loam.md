// Prints ms until process PID shows an on-screen window larger than 400x300, polling every 5 ms.
// Usage: winwait PID START_EPOCH_MS TIMEOUT_MS
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let pid = Int(args[1])!, start = Double(args[2])!, timeout = Double(args[3])!
func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
while nowMs() - start < timeout {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int) == pid {
        if let b = w[kCGWindowBounds as String] as? [String: Double], b["Width"]! > 400, b["Height"]! > 300 {
            print(Int(nowMs() - start)); exit(0)
        }
    }
    usleep(5000)
}
print(-1); exit(1)
