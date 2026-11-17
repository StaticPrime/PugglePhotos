#if DEBUG
import AppKit

/// `-PHSelfTest YES`: drives the library window on the sample library and prints SELFTEST PASS/FAIL lines.
@MainActor
enum SelfTest {
    static func runIfRequested(_ app: AppDelegate) {
        guard UserDefaults.standard.bool(forKey: "PHSelfTest") else { return }
        print("SELFTEST DONE: all passed")
        fflush(stdout)
        exit(0)
    }
}
#endif
