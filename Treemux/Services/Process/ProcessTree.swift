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

    // MARK: - Environment reading

    /// Reads the environment variables of a process using KERN_PROCARGS2.
    /// Returns nil if the process cannot be read (wrong user, zombie, invalid PID).
    static func processEnvironment(pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0

        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        // Layout: argc (Int32) | exec_path\0 | padding NULLs | argv[0]\0 ... argv[argc-1]\0 | env[0]\0 ...
        let argc = buffer.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: Int32.self, capacity: 1) { $0.pointee }
        }

        var offset = MemoryLayout<Int32>.size

        // Skip exec_path
        while offset < size, buffer[offset] != 0 { offset += 1 }
        // Skip trailing NULLs after exec_path
        while offset < size, buffer[offset] == 0 { offset += 1 }

        // Skip argv[0..argc-1]
        var argsSeen: Int32 = 0
        while offset < size, argsSeen < argc {
            while offset < size, buffer[offset] != 0 { offset += 1 }
            offset += 1
            argsSeen += 1
        }

        // Parse environment variables
        var env: [String: String] = [:]
        while offset < size {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            if offset > start,
               let entry = String(bytes: buffer[start..<offset], encoding: .utf8),
               let eqIdx = entry.firstIndex(of: "=") {
                env[String(entry[..<eqIdx])] = String(entry[entry.index(after: eqIdx)...])
            }
            offset += 1
        }

        return env.isEmpty ? nil : env
    }

    // MARK: - Descendant lookup

    /// Finds the first descendant of `rootPID` whose environment contains `envKey=envValue`.
    static func findDescendant(
        of rootPID: pid_t,
        envKey: String,
        envValue: String
    ) -> pid_t? {
        for pid in descendants(of: rootPID) {
            if let env = processEnvironment(pid: pid),
               env[envKey] == envValue {
                return pid
            }
        }
        return nil
    }

    // MARK: - Tmux client list parsing

    /// Parses the output of `tmux list-clients -F '#{client_pid} #{session_name}'`.
    static func parseTmuxClientList(
        _ output: String
    ) -> [(clientPID: pid_t, sessionName: String)] {
        output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            return (clientPID: pid, sessionName: String(parts[1]))
        }
    }
}
