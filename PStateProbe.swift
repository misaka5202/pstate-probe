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
//  with EFF_INTERVAL 0.15 s, step-up 45% busy, step-down 25% busy. That is the
//  same idea as Windows' automatic boost.
//
//  Two things switch it off, and neither is exposed:
//
//    pmRyzen_pstatelimit == 0   set_PState() returns immediately
//    _tscFreq missing or zero   pmRyzen_machine_idle() skips the whole block,
//                               because a zero time base would pin every core
//                               at P0. htmambo's 0.7.6 added that guard on
//                               purpose.
//
//  So the state is inferred from behaviour: sample the P-State index and the
//  per-core clocks while idle, then while loaded, and compare.
//
//  Reading the driver correctly
//  ----------------------------
//  Every selector here returns through structureOutput, not scalarOutput -
//  AMDRyzenCPUPMUserClient.cpp puts the values in dataOut and only sets
//  scalarOutputCount = 0. The first version of this tool used
//  IOConnectCallScalarMethod and therefore read nothing at all, which looked
//  exactly like a dead driver. It uses IOConnectCallMethod throughout now.
//
//    selector  0   kMSR_PSTATE_LEN (8) uint64 P-State definitions
//    selector  1   kMSR_PSTATE_LEN (8) float  P-State clocks in MHz
//    selector  4   [power, temp, pstateCur, freq0..freqN-1]
//    selector  9   1 uint64 - PStateCtl (the target state)
//    selector 11   2 uint64 - [cpbSupported, cpbState]
//
//  Build:
//    swiftc -O -o pstateprobe PStateProbe.swift
//
//  Run:
//    ./pstateprobe           20 seconds
//    ./pstateprobe 40        40 seconds
//
//  Stay idle for the first half, then open something heavy. The two halves are
//  summarised separately.
//

import Foundation
import IOKit

private let serviceName = "AMDRyzenCPUPowerManagement"
private let kPStateLen = 8

final class Driver {
    private var connect: io_connect_t = 0

    func open() -> (ok: Bool, kr: kern_return_t) {
        let service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                  IOServiceMatching(serviceName))
        guard service != 0 else { return (false, KERN_FAILURE) }
        defer { IOObjectRelease(service) }

        let kr = IOServiceOpen(service, mach_task_self_, 0, &connect)
        return (kr == KERN_SUCCESS, kr)
    }

    func close() {
        if connect != 0 { IOServiceClose(connect); connect = 0 }
    }

    /// Generic structure-output call. Every selector in this driver uses this
    /// shape: values land in structureOutput, scalarOutputCount is cleared.
    private func structureCall(_ selector: UInt32,
                               outBytes: Int) -> (kr: kern_return_t, bytes: [UInt8]) {
        var out = [UInt8](repeating: 0, count: outBytes)
        var outSize = outBytes
        let kr = IOConnectCallMethod(connect, selector,
                                     nil, 0, nil, 0,
                                     nil, nil, &out, &outSize)
        return (kr, out)
    }

    private func asU64(_ bytes: [UInt8], _ count: Int) -> [UInt64] {
        var v = [UInt64](repeating: 0, count: count)
        let need = count * MemoryLayout<UInt64>.size
        if bytes.count >= need {
            bytes.withUnsafeBytes { raw in
                for i in 0..<count { v[i] = raw.load(fromByteOffset: i * 8, as: UInt64.self) }
            }
        }
        return v
    }

    private func asF32(_ bytes: [UInt8], _ count: Int) -> [Float] {
        var v = [Float](repeating: 0, count: count)
        let need = count * MemoryLayout<Float>.size
        if bytes.count >= need {
            bytes.withUnsafeBytes { raw in
                for i in 0..<count { v[i] = raw.load(fromByteOffset: i * 4, as: Float.self) }
            }
        }
        return v
    }

    /// Selector 0: raw P-State definitions. A usable entry has a non-zero
    /// low byte (the enabled/regulator bit plus frequency id).
    func pStateDefs() -> (kr: kern_return_t, defs: [UInt64]) {
        let r = structureCall(0, outBytes: kPStateLen * 8)
        return (r.kr, asU64(r.bytes, kPStateLen))
    }

    /// Selector 1: P-State clocks in MHz.
    func pStateClocks() -> (kr: kern_return_t, mhz: [Float]) {
        let r = structureCall(1, outBytes: kPStateLen * 4)
        return (r.kr, asF32(r.bytes, kPStateLen))
    }

    /// Selector 4: [power, temperature, pstateCur, freq0, freq1, ...].
    /// The count depends on the core count, so ask for a generous buffer and
    /// use whatever the kernel reports back.
    func metrics() -> (kr: kern_return_t, values: [Float]) {
        let maxCores = 64
        let r = structureCall(4, outBytes: (maxCores + 3) * 4)
        let v = asF32(r.bytes, maxCores + 3)
        return (r.kr, v)
    }

    /// Selector 9: one uint64, the current PStateCtl.
    func currentPState() -> (kr: kern_return_t, state: Int) {
        let r = structureCall(9, outBytes: 8)
        let v = asU64(r.bytes, 1)
        return (r.kr, Int(v[0]))
    }

    /// Selector 11: [cpbSupported, cpbState].
    func cpb() -> (kr: kern_return_t, supported: Bool, enabled: Bool) {
        let r = structureCall(11, outBytes: 16)
        let v = asU64(r.bytes, 2)
        return (r.kr, v[0] != 0, v[1] != 0)
    }

    /// Selector 8: version string, also structure output.
    func version() -> String {
        var buf = [UInt8](repeating: 0, count: 64)
        var size = 64
        let kr = IOConnectCallMethod(connect, 8, nil, 0, nil, 0,
                                     nil, nil, &buf, &size)
        guard kr == KERN_SUCCESS else { return "?" }
        return String(cString: buf.map { CChar(bitPattern: $0) })
    }
}

struct Sample {
    let pstate: Int
    let maxClock: Float
    let temp: Float
}

final class PStateProbe {
    static func run() {
        let seconds = CommandLine.arguments.count > 1
            ? (Int(CommandLine.arguments[1]) ?? 20) : 20

        print("=== AMD P-State governor probe ===")
        print("")

        let d = Driver()
        let opened = d.open()
        guard opened.ok else {
            print(String(format: "IOServiceOpen failed: 0x%X", opened.kr))
            print("kext loaded? check:  kmutil showloaded | grep -i amdryzen")
            exit(1)
        }
        defer { d.close() }

        print("kext version : \(d.version())")

        // P-State table.
        let defs = d.pStateDefs()
        let clocks = d.pStateClocks()
        let validDefs = defs.defs.filter { $0 != 0 }
        let validClocks = clocks.mhz.filter { $0 > 0 }

        print(String(format: "selector 0   : kr=0x%X  %d non-zero entries",
                     defs.kr, validDefs.count))
        if !validClocks.isEmpty {
            let s = validClocks.map { String(format: "%.0f", $0) }.joined(separator: " ")
            print("P-State MHz  : \(s)")
        } else {
            print(String(format: "selector 1   : kr=0x%X  no clocks", clocks.kr))
        }

        let c = d.cpb()
        print(String(format: "CPB          : kr=0x%X  %@, %@",
                     c.kr,
                     c.supported ? "supported" : "unsupported",
                     c.enabled ? "on" : "off"))

        let ps = d.currentPState()
        print(String(format: "PStateCtl    : kr=0x%X  %d", ps.kr, ps.state))
        print("")

        // If even the first read is empty, say so plainly instead of sampling
        // twenty seconds of nothing.
        if validClocks.isEmpty && ps.kr != KERN_SUCCESS {
            print("every selector returned nothing.")
            print("the connection opened but the client did not start -")
            print("check:  log show --last 5m | grep AMDCPUSupportUserClient")
            exit(1)
        }

        func sampleOnce() -> Sample? {
            let p = d.currentPState()
            guard p.kr == KERN_SUCCESS else { return nil }
            let m = d.metrics()
            guard m.kr == KERN_SUCCESS, m.values.count > 3 else { return nil }
            let temp = m.values[1]
            let freqs = Array(m.values[3...]).filter { $0 > 0 }
            return Sample(pstate: p.state, maxClock: freqs.max() ?? 0, temp: temp)
        }

        let half = max(1, seconds / 2)
        var first: [Sample] = []
        var second: [Sample] = []

        func runPhase(_ into: inout [Sample], label: String) {
            for i in 0..<half {
                if let s = sampleOnce() {
                    into.append(s)
                    print(String(format: "  %@ %2ds  P-State %d  %4.0f MHz  %3.0f C",
                                 label, i + 1, s.pstate, s.maxClock, s.temp))
                } else {
                    print("  \(label) \(i+1)s  <no data>")
                }
                Thread.sleep(forTimeInterval: 1.0)
            }
        }

        print("phase 1 of 2 - stay idle")
        runPhase(&first, label: "idle")
        print("")
        print("phase 2 of 2 - open something heavy now")
        runPhase(&second, label: "load")
        print("")

        func summarise(_ s: [Sample], _ name: String) {
            guard !s.isEmpty else { print("\(name): no samples"); return }
            let ps = s.map { $0.pstate }
            let cl = s.map { $0.maxClock }
            let tp = s.map { $0.temp }
            print("\(name):")
            print("  P-State  min \(ps.min()!)  max \(ps.max()!)  distinct \(Set(ps).sorted())")
            print(String(format: "  clock    min %.0f  max %.0f  avg %.0f MHz",
                         cl.min()!, cl.max()!, cl.reduce(0, +) / Float(cl.count)))
            print(String(format: "  temp     min %.0f  max %.0f  avg %.0f C",
                         tp.min()!, tp.max()!, tp.reduce(0, +) / Float(tp.count)))
        }

        print("=== summary ===")
        summarise(first, "phase 1 (idle)")
        summarise(second, "phase 2 (load)")
        print("")

        let all = first + second
        let states = Set(all.map { $0.pstate })
        let clocksAll = all.map { $0.maxClock }

        print("=== verdict ===")
        if states.count > 1 {
            print("  governor ALIVE: P-State moved between \(states.sorted())")
            print("  the load-based governor in pmRyzen_machine_idle() is working.")
        } else {
            print("  governor STUCK: P-State stayed at \(states.first ?? -1) for every sample")
            print("  either pmRyzen_pstatelimit is 0, or _tscFreq was missing at boot.")
            print("  check:  log show --last boot | grep -i amdcpu")
        }
        if let lo = clocksAll.min(), let hi = clocksAll.max() {
            print(String(format: "  clock swing: %.0f MHz (%.0f -> %.0f)", hi - lo, lo, hi))
        }
    }
}

PStateProbe.run()
