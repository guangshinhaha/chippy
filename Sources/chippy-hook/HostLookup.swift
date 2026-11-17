import AppKit
import ChippyCore
import Darwin

/// Finds the GUI app (and tty) hosting this relay, via the process ancestry. Any failure yields nil: fail-open.
enum HostLookup {
    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    static func find() -> (pid: Int32, bundle: String?, tty: String?)? {
        var bundle: String?
        let r = ProcessTree.walk(
            start: getpid(),
            parent: { kinfo($0).map { $0.kp_eproc.e_ppid } },
            isApp: { pid in
                guard let app = NSRunningApplication(processIdentifier: pid), ProcessTree.isGUIHost(regularApp: app.activationPolicy == .regular, bundleId: app.bundleIdentifier) else { return false }
                bundle = app.bundleIdentifier
                return true
            },
            tty: { pid in
                guard let k = kinfo(pid), k.kp_eproc.e_tdev != -1 else { return nil }
                guard let n = devname(dev_t(k.kp_eproc.e_tdev), S_IFCHR) else { return nil }
                return String(cString: n)
            })
        guard r.hostPid != nil || r.tty != nil else { return nil }
        return (r.hostPid ?? 0, bundle, r.tty)
    }
}
