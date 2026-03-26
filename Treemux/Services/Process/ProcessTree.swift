//
//  ProcessTree.swift
//  Treemux
//

import Darwin
import Foundation

/// Walks the macOS process tree using sysctl to discover descendant processes
/// and read their environment variables.
enum ProcessTree {

    struct ProcessEntry {
        let pid: pid_t
        let parentPID: pid_t
        let command: String
    }

    // MARK: - Process enumeration

    /// Returns all processes visible to the current user.
    static func allProcesses() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > 0 else { return [] }

        // Over-allocate to handle process list growth between the two sysctl calls.
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procList = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride

        guard sysctl(&mib, UInt32(mib.count), &procList, &size, nil, 0) == 0 else { return [] }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        return (0..<actualCount).map { i in
            let kp = procList[i]
            let comm = withUnsafePointer(to: kp.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: kp.kp_proc.p_comm)
                ) { String(cString: $0) }
            }
            return ProcessEntry(
                pid: kp.kp_proc.p_pid,
                parentPID: kp.kp_eproc.e_ppid,
                command: comm
            )
        }
    }

    // MARK: - Tree walking

    /// Returns all descendant PIDs of `rootPID` (not including `rootPID` itself).
    static func descendants(of rootPID: pid_t) -> Set<pid_t> {
        let all = allProcesses()
        var children: [pid_t: [pid_t]] = [:]
        for entry in all {
            children[entry.parentPID, default: []].append(entry.pid)
        }

        var result = Set<pid_t>()
        var queue = children[rootPID] ?? []
        var idx = 0
        while idx < queue.count {
            let pid = queue[idx]
            idx += 1
            guard result.insert(pid).inserted else { continue }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return result
    }
}
