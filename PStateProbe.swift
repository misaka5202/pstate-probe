//
//  PStateProbe.swift
//
//  Is the CPU actually stepping between P-States on its own?
//
//  Why this exists
//  ---------------
//  The kext contains a real load-based governor in pmRyzen_machine_idle():
//
//      if (rt > pmRyzen_p_sutsc)            set_PState(cpu, PState - 1);
//      else if (rt < pmRyzen_p_sdtsc) { ... set_PState(cpu, PState + 1); }
//
//  with thresholds EFF_INTERVAL 0.15 s, step-up 45% busy, step-down 25% busy.
//  That is the same idea as Windows' automatic boost: watch how much of each
//  window the core spends running, and move up or down the P-State table.
//
//  Two things can switch it off, and neither is visible without measuring:
//
//    set_PState() starts with   if (pmRyzen_pstatelimit == 0) return;
//    so a limit of 0 disables the governor entirely, and a limit of 1 clamps
//    it to P0/P1 - a range so narrow that the CPU looks pinned.
//
//    pmRyzen_machine_idle() skips the whole block when pmRyzen_tsc_freq == 0,
//    which happens when the kernel symbol _tscFreq is missing or zero on a
//    newer macOS. htmambo's 0.7.6 added that guard deliberately, because a
//    zero time base would make the busy comparison always true and pin every
//    core at P0.
//
//  Neither variable is exposed through the IOUserClient, so this tool infers
//  the state from behaviour instead:
//
//    * how many P-States the firmware exposes       (selector 0)
//    * which P-State each core sits at, sampled     (selector 9)
//    * the effective clock per core, sampled        (selector 4)
//
//  If the P-State index moves while the machine is idle then busy, the
//  governor is alive. If it never moves, it is dead - and that is the answer,
//  regardless of which of the two guards caused it.
//
//  Build:
//    swiftc -O -o pstateprobe PStateProbe.swift
//
//  Run:
//    ./pstateprobe            sample for 20 seconds, then summarise
//    ./pstateprobe 60         sample for 60 seconds
//
//  While it runs, be deliberate: sit idle for the first half, then open
//  something heavy. The summary prints both halves separately so the two
//  regimes can be compared directly.
//

import Foundation
import IOKit

// MARK: - Driver connection

/// Matches the same service the helper app talks to.
private let serviceName = "AMDRyzenCPUPowerManagement"

final class Driver {
    private var connect: io_connect_t = 0

    func open() -> Bool {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                 IOServiceMatching(serviceName))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connect)
        return kr == KERN_SUCCESS
    }

    func close() {
        if connect != 0 {
            IOServiceClose(connect)
            connect = 0
        }
    }

    /// Selector 0: raw P-State definitions for core 0.
    /// Returns the number of entries that look populated.
    func pStateCount() -> Int {
        var out = [UInt64](repeating: 0, count: 8)
        var outCount: UInt32 = 8
        let kr = IOConnectCallScalarMethod(connect, 0, nil, 0, &out, &outCount)
        guard kr == KERN_SUCCESS else { return 0 }

        // A populated entry has a non-zero frequency id in its low byte.
        var n = 0
        for v in out where v != 0 { n += 1 }
        return n
    }

    /// Selector 1: P-State clocks in MHz, one per valid state.
    func pStateClocks() -> [Float] {
        var out = [Float](repeating: 0, count: 10)
        var outCount: Int = 10 * MemoryLayout<Float>.size
        let kr = IOConnectCallMethod(connect, 1, nil, 0, nil, 0,
                                     nil, nil, &out, &outCount)
        guard kr == KERN_SUCCESS else { return [] }
        return out.filter { $0 > 0 }
    }

    /// Selector 4: [power, temperature, pstateCur, freq0, freq1, ...]
    func metrics() -> [Float] {
        var out = [Float](repeating: 0, count: 67)
        var outCount: Int = 67 * MemoryLayout<Float>.size
        let kr = IOConnectCallMethod(connect, 4, nil, 0, nil, 0,
                                     nil, nil, &out, &outCount)
        guard kr == KERN_SUCCESS else { return [] }
        return out
    }

    /// Selector 9: current P-State index.
    func currentPState() -> Int? {
        var out = [UInt64](repeating: 0, count: 1)
        var outCount: UInt32 = 1
        let kr = IOConnectCallScalarMethod(connect, 9, nil, 0, &out, &outCount)
        guard kr == KERN_SUCCESS else { return nil }
        return Int(out[0])
    }

    /// Selector 11: [supported, enabled] for CPB.
    func cpb() -> (supported: Bool, enabled: Bool) {
        var out = [UInt64](repeating: 0, count: 2)
        var outCount: UInt32 = 2
        let kr = IOConnectCallScalarMethod(connect, 11, nil, 0, &out, &outCount)
        guard kr == KERN_SUCCESS else { return (false, false) }
        return (out[0] != 0, out[1] != 0)
    }

    /// Selector 8: kext version string.
    func version() -> String {
        var buf = [CChar](repeating: 0, count: 128)
        var size = 128
        let kr = IOConnectCallMethod(connect, 8, nil, 0, nil, 0,
                                     nil, nil, &buf, &size)
        guard kr == KERN_SUCCESS else { return "?" }
        return String(cString: buf)
    }
}

// MARK: - Sampling

struct Sample {
    let pstate: Int
    let maxClock: Float
    let temp: Float
}

func sampleOnce(_ d: Driver) -> Sample? {
    guard let ps = d.currentPState() else { return nil }
    let m = d.metrics()
    guard m.count > 3 else { return nil }
    let temp = m.count > 1 ? m[1] : 0
    let clocks = Array(m[3...])
    return Sample(pstate: ps, maxClock: clocks.max() ?? 0, temp: temp)
}

// MARK: - Main

final class PStateProbe {
    static func run() {
        let args = CommandLine.arguments
        let seconds = args.count > 1 ? (Int(args[1]) ?? 20) : 20

        print("=== AMD P-State governor probe ===")
        print("")

        let d = Driver()
        guard d.open() else {
            print("could not open \(serviceName).")
            print("is AMDRyzenCPUPowerManagement loaded? check:")
            print("  ioreg -l | grep -i amdryzen")
            exit(1)
        }
        defer { d.close() }

        print("kext version : \(d.version())")

        let count = d.pStateCount()
        let clocks = d.pStateClocks()
        print("P-State count: \(count)")
        if !clocks.isEmpty {
            let s = clocks.map { String(format: "%.0f", $0) }.joined(separator: " ")
            print("P-State MHz  : \(s)")
        }

        let c = d.cpb()
        print("CPB          : \(c.supported ? "supported" : "unsupported"), "
              + "currently \(c.enabled ? "on" : "off")")
        print("")

        // Sample. The caller is expected to idle for the first half and work
        // for the second, so the two are reported apart.
        let half = max(1, seconds / 2)
        var first: [Sample] = []
        var second: [Sample] = []

        func tick(_ into: inout [Sample], label: String) {
            var lastReport = ""
            for i in 0..<half {
                if let s = sampleOnce(d) {
                    into.append(s)
                    lastReport = String(format: "  %@ %2ds  P-State %d  %4.0f MHz  %3.0f C",
                                        label, i + 1, s.pstate, s.maxClock, s.temp)
                    print(lastReport)
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }

        print("phase 1 of 2 - stay idle")
        tick(&first, label: "idle")
        print("")
        print("phase 2 of 2 - open something heavy now")
        tick(&second, label: "load")
        print("")

        // Summary.
        func summarise(_ s: [Sample], _ name: String) {
            guard !s.isEmpty else { print("\(name): no samples"); return }
            let ps = s.map { $0.pstate }
            let clocks = s.map { $0.maxClock }
            let temps = s.map { $0.temp }
            let distinct = Set(ps).sorted()
            print("\(name):")
            print("  P-State  min \(ps.min()!)  max \(ps.max()!)  distinct \(distinct)")
            print(String(format: "  clock    min %.0f  max %.0f  avg %.0f MHz",
                         clocks.min()!, clocks.max()!, clocks.reduce(0, +) / Float(clocks.count)))
            print(String(format: "  temp     min %.0f  max %.0f  avg %.0f C",
                         temps.min()!, temps.max()!, temps.reduce(0, +) / Float(temps.count)))
        }

        print("=== summary ===")
        summarise(first, "phase 1 (idle)")
        summarise(second, "phase 2 (load)")
        print("")

        // Verdict. The governor is judged on whether the index moved at all,
        // not on how far - a limit of 1 is still a working governor, just a
        // very narrow one, and that distinction matters for what to change.
        let all = first + second
        let allStates = Set(all.map { $0.pstate })
        let allClocks = all.map { $0.maxClock }

        print("=== verdict ===")
        if allStates.count > 1 {
            print("  governor ALIVE: P-State index moved between \(allStates.sorted())")
            print("  the load-based governor in pmRyzen_machine_idle() is working.")
        } else {
            print("  governor DEAD: P-State stayed at \(allStates.first ?? -1) for every sample")
            print("  either pmRyzen_pstatelimit is 0/1, or _tscFreq was missing at boot.")
            print("  check the kext log:  log show --last boot | grep -i amdcpu")
        }

        if let lo = allClocks.min(), let hi = allClocks.max() {
            let swing = hi - lo
            print(String(format: "  clock swing: %.0f MHz (%.0f -> %.0f)", swing, lo, hi))
            if swing < 200 && allStates.count <= 1 {
                print("  a swing this small with a fixed P-State means the CPU")
                print("  never left one operating point - consistent with a dead governor.")
            }
        }
    }
}

PStateProbe.run()
