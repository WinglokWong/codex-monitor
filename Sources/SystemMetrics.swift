import Foundation
import Darwin
import SystemConfiguration

struct SystemSnapshot {
    let sampledAt: Date
    let cpuPercent: Double?
    let memoryUsedBytes: UInt64?
    let memoryTotalBytes: UInt64
    let downloadBytesPerSecond: Double?
    let uploadBytesPerSecond: Double?
    let interfaces: [String]
    let error: String?
}

private struct InterfaceCounter {
    let index: UInt32
    let changedSeconds: Int64
    let changedMicroseconds: Int64
    let received: UInt64
    let sent: UInt64

    func hasSameIdentity(as other: InterfaceCounter) -> Bool {
        index == other.index && changedSeconds == other.changedSeconds &&
            changedMicroseconds == other.changedMicroseconds
    }
}

private enum MetricReadError: Error, CustomStringConvertible {
    case unavailable(String)
    var description: String {
        switch self { case .unavailable(let message): return message }
    }
}

private func cpuPercentage(previous: [UInt32], current: [UInt32]) -> Double? {
    guard previous.count == Int(CPU_STATE_MAX), current.count == previous.count else { return nil }
    // HOST_CPU_LOAD_INFO ticks are 32-bit cumulative counters; wrapping subtraction
    // handles a counter passing UInt32.max during otherwise normal operation.
    let deltas = zip(current, previous).map { UInt64($0 &- $1) }
    let total = deltas.reduce(UInt64(0), +)
    guard total > 0 else { return nil }
    return 100 * Double(total - deltas[Int(CPU_STATE_IDLE)]) / Double(total)
}

private func networkRates(previous: [String: InterfaceCounter], current: [String: InterfaceCounter],
                          elapsed: Double) -> (download: Double, upload: Double)? {
    guard elapsed > 0, elapsed <= 10, !current.isEmpty,
          Set(previous.keys) == Set(current.keys) else { return nil }
    var received = 0.0
    var sent = 0.0
    for (name, counter) in current {
        guard let old = previous[name], counter.hasSameIdentity(as: old),
              counter.received >= old.received, counter.sent >= old.sent else {
            // Treat a reset, replaced interface, or theoretical UInt64 wrap as a
            // new baseline. Never turn it into a huge negative/overflowing rate.
            return nil
        }
        received += Double(counter.received - old.received)
        sent += Double(counter.sent - old.sent)
    }
    return (received / elapsed, sent / elapsed)
}

/// Own one instance on a serial queue and call sample() about once a second.
final class SystemSampler {
    private let host = mach_host_self()
    private let totalMemory = ProcessInfo.processInfo.physicalMemory
    private var previousCPU: (time: Double, ticks: [UInt32])?
    private var previousNetwork: (time: Double, counters: [String: InterfaceCounter])?
    private let secondsPerTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func sample() -> SystemSnapshot {
        // Continuous time includes sleep, unlike wall-clock time (which can jump).
        // A gap over ten seconds intentionally needs a fresh CPU/network baseline.
        let now = Double(mach_continuous_time()) * secondsPerTick
        var errors: [String] = []
        var cpu: Double?
        var memory: UInt64?
        var download: Double?
        var upload: Double?
        var names: [String] = []

        do {
            let ticks = try readCPUTicks()
            if let previous = previousCPU, now > previous.time, now - previous.time <= 10 {
                cpu = cpuPercentage(previous: previous.ticks, current: ticks)
            }
            previousCPU = (now, ticks)
        } catch {
            previousCPU = nil
            errors.append(String(describing: error))
        }
        do { memory = try readMemoryUsed() }
        catch { errors.append(String(describing: error)) }
        do {
            let counters = try readPhysicalNetworkCounters()
            names = counters.keys.sorted()
            if let previous = previousNetwork,
               let rates = networkRates(previous: previous.counters, current: counters,
                                        elapsed: now - previous.time) {
                download = rates.download
                upload = rates.upload
            }
            previousNetwork = (now, counters)
        } catch {
            previousNetwork = nil
            errors.append(String(describing: error))
        }
        return SystemSnapshot(sampledAt: Date(), cpuPercent: cpu, memoryUsedBytes: memory,
                              memoryTotalBytes: totalMemory, downloadBytesPerSecond: download,
                              uploadBytesPerSecond: upload, interfaces: names,
                              error: errors.isEmpty ? nil : errors.joined(separator: "；"))
    }

    private func readCPUTicks() throws -> [UInt32] {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw MetricReadError.unavailable("CPU 读取失败（\(result)）")
        }
        return [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
    }

    private func readMemoryUsed() throws -> UInt64 {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var pageSize = vm_size_t(0)
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS,
              pageSize > 0 else {
            throw MetricReadError.unavailable("内存读取失败（\(result)）")
        }
        // Activity-Monitor-like physical usage estimate:
        // app = resident anonymous/internal pages minus reclaimable purgeable pages;
        // used = app + wired + the compressor's actual physical pages.
        // File-backed cache is excluded. Do NOT add active/inactive pages, swap, or
        // total_uncompressed_pages_in_compressor: those would count data twice or
        // count bytes not physically resident. This is not a memory-pressure score
        // and may differ slightly from Activity Monitor's private accounting.
        let appPages = max(Int64(info.internal_page_count) - Int64(info.purgeable_count), 0)
        let usedPages = UInt64(appPages) + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
        return min(usedPages * UInt64(pageSize), totalMemory)
    }

    private func readPhysicalNetworkCounters() throws -> [String: InterfaceCounter] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            throw MetricReadError.unavailable("物理网卡列表暂不可用")
        }
        let physicalNames = Set(interfaces.compactMap { interface -> String? in
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  name.hasPrefix("en"),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  type == (kSCNetworkInterfaceTypeEthernet as String) ||
                    type == (kSCNetworkInterfaceTypeIEEE80211 as String) else { return nil }
            return name
        })
        // Count physical Ethernet/Wi-Fi interfaces once. Never add utun VPN,
        // loopback, AWDL, or a bridge on top of its physical member interfaces.
        // This measures all physical traffic, including LAN/VPN transport overhead,
        // rather than claiming to measure only Internet payload or the default route.
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        defer { if descriptor >= 0 { close(descriptor) } }
        let data = try readInterfaceMessages()
        return try data.withUnsafeBytes { buffer in
            var output: [String: InterfaceCounter] = [:]
            var offset = 0
            while offset < buffer.count {
                guard offset + 4 <= buffer.count else {
                    throw MetricReadError.unavailable("网卡统计消息不完整")
                }
                let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, offset + length <= buffer.count else {
                    throw MetricReadError.unavailable("网卡统计消息长度无效")
                }
                defer { offset += length }
                guard buffer[offset + 3] == RTM_IFINFO2 else { continue }
                guard length >= MemoryLayout<if_msghdr2>.size else {
                    throw MetricReadError.unavailable("网卡统计消息不完整")
                }
                let info = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard info.ifm_flags & IFF_UP != 0, info.ifm_flags & IFF_RUNNING != 0 else { continue }
                var cName = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                guard if_indextoname(UInt32(info.ifm_index), &cName) != nil else { continue }
                let name = String(cString: cName)
                guard physicalNames.contains(name) else { continue }
                // IFF_RUNNING alone is also set on an unplugged Ethernet adapter.
                // Unknown media state is allowed: some third-party drivers do not
                // support this query; their physical byte counters remain valid.
                if linkIsActive(name: name, descriptor: descriptor) == false { continue }
                output[name] = InterfaceCounter(index: UInt32(info.ifm_index),
                    changedSeconds: Int64(info.ifm_data.ifi_lastchange.tv_sec),
                    changedMicroseconds: Int64(info.ifm_data.ifi_lastchange.tv_usec),
                    received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
            }
            return output
        }
    }

    private func readInterfaceMessages() throws -> Data {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // An interface can appear between the size query and read; retry ENOMEM.
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else {
                throw MetricReadError.unavailable("网络统计读取失败（\(errno)）")
            }
            guard size > 0 else { return Data() }
            var bytes = Data(count: size)
            let result = bytes.withUnsafeMutableBytes { buffer in
                sysctl(&mib, UInt32(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if result == 0 {
                bytes.count = size
                return bytes
            }
            if errno != ENOMEM {
                throw MetricReadError.unavailable("网络统计读取失败（\(errno)）")
            }
        }
        throw MetricReadError.unavailable("网卡正在变化，等待下一次采样")
    }

    private func linkIsActive(name: String, descriptor: Int32) -> Bool? {
        guard descriptor >= 0 else { return nil }
        var request = ifmediareq()
        let nameBytes = Array(name.utf8CString)
        guard nameBytes.count <= MemoryLayout.size(ofValue: request.ifm_name) else { return nil }
        withUnsafeMutableBytes(of: &request.ifm_name) { buffer in
            for index in nameBytes.indices { buffer[index] = UInt8(bitPattern: nameBytes[index]) }
        }
        // Darwin's SIOCGIFMEDIA = _IOWR('i', 56, struct ifmediareq). Swift cannot
        // import that structure-dependent C macro, so reproduce the public SDK
        // encoding while deriving its size from the imported native structure.
        let command = UInt(IOC_INOUT) | (UInt(MemoryLayout<ifmediareq>.size & 0x1fff) << 16) |
            (UInt(105) << 8) | 56
        guard ioctl(descriptor, command, &request) == 0,
              request.ifm_status & IFM_AVALID != 0 else { return nil }
        return request.ifm_status & IFM_ACTIVE != 0
    }
}

func runSystemMetricTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw MetricReadError.unavailable("System metrics test: \(message)") }
    }
    let cpu = cpuPercentage(previous: [100, 50, 850, 0], current: [120, 60, 920, 0])
    try require(cpu == 30, "CPU must use interval ticks, including idle")
    let wrappedCPU = cpuPercentage(previous: [UInt32.max - 4, 0, 10, 0], current: [5, 0, 20, 0])
    try require(wrappedCPU == 50, "32-bit CPU wrap must preserve interval usage")
    try require(cpuPercentage(previous: [1, 2, 3, 4], current: [1, 2, 3, 4]) == nil,
                "unchanged kernel counters must not fabricate zero CPU")

    func counter(_ received: UInt64, _ sent: UInt64, index: UInt32 = 1,
                 changed: Int64 = 0) -> InterfaceCounter {
        InterfaceCounter(index: index, changedSeconds: changed, changedMicroseconds: 0,
                         received: received, sent: sent)
    }
    let old = ["en0": counter(5_000_000_000, 9_000_000_000), "en1": counter(100, 200, index: 2)]
    let new = ["en0": counter(5_000_001_000, 9_000_002_000), "en1": counter(600, 1_200, index: 2)]
    let rates = networkRates(previous: old, current: new, elapsed: 2)
    try require(rates?.download == 750 && rates?.upload == 1_500,
                "64-bit counts from two interfaces must use actual elapsed time")
    try require(networkRates(previous: old, current: ["en0": new["en0"]!], elapsed: 1) == nil,
                "removing an interface needs a new baseline")
    try require(networkRates(previous: ["en0": counter(100, 200)],
                             current: ["en0": counter(1, 2)], elapsed: 1) == nil,
                "counter reset must not generate a rate spike")
    try require(networkRates(previous: ["en0": counter(100, 200)],
                             current: ["en0": counter(200, 300, changed: 1)], elapsed: 1) == nil,
                "reconnecting an interface needs a new baseline")
    try require(networkRates(previous: old, current: new, elapsed: 30) == nil,
                "sleep or long suspension must discard stale rate baselines")
    try require(networkRates(previous: [:], current: [:], elapsed: 1) == nil,
                "no physical connection must not pretend to be measured zero traffic")
}
