# pstate-probe

Answers one question: **is the AMD P-State governor in
`AMDRyzenCPUPowerManagement` actually stepping the CPU, or is it stuck?**

## Why this matters

The kext contains a load-based governor in `pmRyzen_machine_idle()`. Every
150 ms it compares how long the core spent running against two thresholds and
moves up or down the P-State table:

```c
if (rt > pmRyzen_p_sutsc)            set_PState(cpu, PState - 1);
else if (rt < pmRyzen_p_sdtsc) { ... set_PState(cpu, PState + 1); }
```

with `EFF_INTERVAL 0.15`, step-up 45% busy, step-down 25% busy. That is the
same idea as Windows' automatic boost.

Two things can switch it off, and neither is exposed through the IOUserClient:

| guard | effect |
|---|---|
| `pmRyzen_pstatelimit == 0` | `set_PState()` returns immediately; nothing ever moves |
| `_tscFreq` missing or zero | `pmRyzen_machine_idle()` skips the whole block, because a zero time base would make the busy test always true and pin every core at P0 |

htmambo's 0.7.6 added the second guard deliberately — it is a fix, not a bug,
but it means the governor silently does nothing on systems where the symbol is
gone.

## What it does instead of reading those variables

It measures behaviour:

| selector | returns |
|---|---|
| 0 | raw P-State definitions, used to count the available states |
| 1 | P-State clocks in MHz |
| 4 | `[power, temperature, pstateCur, freq0, freq1, ...]` |
| 9 | current P-State index |
| 11 | `[CPB supported, CPB enabled]` |

If the index moves, the governor is alive. If it never moves, it is dead —
regardless of which guard caused it.

## Use

```sh
./pstateprobe        # 20 seconds
./pstateprobe 60     # 60 seconds
```

The run is split in two halves and reported separately:

* **phase 1** — stay idle, don't touch anything
* **phase 2** — open something heavy

That way the two regimes can be compared directly. A governor that works will
show a different P-State index in the two phases.

Sample output:

```
=== AMD P-State governor probe ===

kext version : 0.7.6
P-State count: 3
P-State MHz  : 3000 2200 1400
CPB          : supported, currently on

phase 1 of 2 - stay idle
  idle  1s  P-State 2  1397 MHz  46 C
  ...

=== verdict ===
  governor ALIVE: P-State index moved between [0, 2]
  the load-based governor in pmRyzen_machine_idle() is working.
  clock swing: 1603 MHz (1397 -> 3000)
```

## Reading the verdict

| verdict | meaning | what to change |
|---|---|---|
| **ALIVE**, index moves across several states | governor works | nothing on the P-State side; if the machine is still hot, the problem is elsewhere (CPB, cooling, background load) |
| **ALIVE**, but only between two adjacent states | limit is too narrow — likely `setPMPStateLimit(1)` | widen the limit so more of the table is usable |
| **DEAD**, index fixed and clock swing small | governor inactive | check `log show --last boot \| grep -i amdcpu` for `_tscFreq missing` |

## Build

```sh
swiftc -O -target x86_64-apple-macos11.0 \
  -framework IOKit -framework CoreFoundation \
  -o pstateprobe PStateProbe.swift
```

CI builds it on every push and uploads the binary.

## Credits

The IOUserClient selectors and the governor design come from
[trulyspinach/SMCAMDProcessor](https://github.com/trulyspinach/SMCAMDProcessor)
and [htmambo's fork](https://github.com/htmambo/SMCAMDProcessor), which is the
version this targets.
