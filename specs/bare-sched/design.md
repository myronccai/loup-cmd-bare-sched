# Design: bare-sched

## Overview

One kernel, two boards. Each board's entry file attaches its UART to the
console, builds its `Platform` (a template foundation for the CPU composed
with an overlay for the QEMU machine) and calls `demo.run.runKernel`,
which brings the board up, spawns the tasks and turns the boot context
into the idle task. From then on everything happens in tasks, and in the
two interrupt handlers that feed the scheduler.

```text
timer IRQ --> clockTick(): due sleepers -> ready ----+
UART IRQ  --> keyArrived(): key queue, wake input ---+--> preemptIfNeeded() --+
                                                                             |
task: yieldNow / sleepUntil / block / exit --> reschedule() ------------------+--> dispatch()
                                                                                    |
            RunQueue.next(): normal FIFO, then background, else idle <--------------+
            guard check, then Platform.switchStacks(&savedSp[prev], savedSp[next])
```

## Modules

| Module | Role |
|---|---|
| `kernel/platform.lpfree` | `interface Platform`: bring-up, timer, interrupts on, idle, a new task's first frame, the switch, halt |
| `kernel/console.lpfree` | polled output through the board's byte writer; decimal (an `onstack` digit buffer under `@no_zero_locals`), hex, table cells |
| `kernel/queue.lpfree` | `class Queue[T]`: FIFO over a `buffer[T, 8]` with a lower limit |
| `kernel/tasks.lpfree` | the task table (one buffer per column), `Wait`, `TaskState[W]` and its integer encoding, stacks and guards |
| `kernel/sched.lpfree` | `RunQueue`, `dispatch`, the interrupt-side and task-side operations, spawn, the schedule trace, the panic report |
| `kernel/sync.lpfree` | `Semaphore`; the mutexes and their ranked classes `ItemsLock`, `ConsoleLock` |
| `demo/workers.lpfree` | producers, consumer, ticker, counter, hog |
| `demo/monitor.lpfree` | the task table, the trace printout, the keys |
| `demo/run.lpfree` | `runKernel`: banner, bring-up, spawn, start |
| `x86/`, `arm/` | each board's devices, exception handling, context switch, and `board.lpfree` (Platform, panic handler, entry) |
| `selftest/tests.lpfree` | unit tests booted by the self-test images |

## Context switch

A task that is not running is described by its saved stack pointer; its
registers are on its stack. The switch is a call, so it saves only the
registers the calling convention says a call preserves:

| | x86_64 (System V) | aarch64 (AAPCS64) |
|---|---|---|
| Saved | rbx, rbp, r12-r15 (pushes), return address (the call) | x19-x28, x29, x30 (two `stp` each) |
| Frame | `@repr(C) struct SwitchFrame`, 56 bytes | `@align(16) @repr(C) struct SwitchFrame`, 96 bytes |
| New task | r12 = task id, return address = `taskEntry` | x19 = task id, x30 = `taskEntry` |
| `taskEntry` | `sti`, `mov rdi, r12`, `call taskStart` | `msr daifclr, #2`, `mov x0, x19`, `bl taskStart` |

`switchContext` is `@naked` (its body is the assembly, commented line by
line) with `@callconv("sysv64")` / `@callconv("aapcs64")`: the arguments
(where to store the old stack pointer, the new one) are read from the
convention's first two argument registers. The frame types carry a
`const func` size check, so a frame that disagrees with the pushes fails
the build, and `newTaskFrame` builds the first frame with
`PartialInit[SwitchFrame]` (the compiler insists every register gets a
value) before writing it into the stack with `bufSetU64`. The x86_64
freestanding back end uses no SSE registers and the aarch64 one no
floating-point registers, so there is no FP state to switch.

## Scheduling

- Priorities: normal (every demo task), background (the counter), idle
  (task 0). `RunQueue.next()` takes the oldest normal task, else the oldest
  background one, else idle.
- Cooperative within a priority: a normal task keeps the CPU until it
  yields, sleeps, blocks or ends, so a task's output is never cut by
  another task of its priority.
- Preemptive across priorities: each interrupt handler ends with
  `preemptIfNeeded()`, which switches to a higher-priority ready task
  inside the handler. The interrupted task's registers stay in the
  handler's frame on its stack; when it is picked again, `dispatch`
  returns into the handler, which returns from the interrupt.
- Sleep deadlines are absolute ticks (`sleepUntil(k * period)`), so
  periodic tasks do not drift. `clockTick` wakes due sleepers earliest
  deadline first, then lowest id.
- Interrupt masking: every switch happens in `dispatch` with interrupts
  masked; task-side callers use `irqSaveDisable`/`irqRestore` (they may
  nest), the semaphores and mutexes `InterruptGuard`. Every way back into
  a task restores its own state: `irqRestore`, `iretq`/`eret`, or
  `taskEntry`.
- Stack guards: each task's 16 KiB stack sits above an 8 KiB guard filled
  with a pattern. `dispatch` checks the top of the outgoing task's guard and
  panics (`unreachable`, reported by the board's `@panic_handler`) when it
  was written. Measured high-water marks: 4 KiB on x86_64, 9.5 KiB on
  aarch64, plus up to 2 or 5 KiB when an interrupt lands on top.

## Locks

`RunQueue` is a `synchronized class` with `@lockOrder(40)`; the mutexes'
classes are `@lockOrder(20)` (items) and `@lockOrder(30)` (console). The
consumer holds the items lock while it prints under the console lock
(20, then 30); the monitor holds the console lock while it reads the run
queue (30, then 40). Taking them the other way round is
`E_LOCK_ORDER_ACQUIRE_VIOLATION` at compile time. On one CPU the run
queue's own lock is never contended, because every caller masks
interrupts first; the rank is what keeps the nesting checkable.

The mutex state (owner, wait count) is kept in buffers indexed by mutex
id; each ranked class is the lock's identity and its `acquire`/`release`.
Waiters are not kept in per-object queues: a blocked task's state records
what it waits for and when it started, and `longestWaiter` finds the one
to wake (with eight tasks, a scan).

## Loup 1.26.0 constraints that shaped the code

- `buffer[T, N]` in a generic struct is rejected by Stage0 check
  (`E_STRUCT_CLASS_FIELD`), so `Queue[T]` is a generic class; a class
  instance inside another class reads as garbage, so the ready queues are
  module globals that only `RunQueue`'s modifiers touch.
- A buffer of structs or of enums with payloads holds references, and
  values made at the same place in the code alias: queues hold scalars,
  and the task table stores a state as a code and an argument, with
  `stateOf`/`setState` translating to and from `TaskState[Wait]`. `==` on
  an enum value with a payload is always false, so tests compare through
  `match`.
- An aggregate local without `onstack` is one static block per function:
  the two producers run the same function, so their batch is `onstack`
  (without it, prod-b's values overwrite prod-a's and the sum is 411).
- Functions returning an enum with a payload (`stateOf`, `Queue.pop`)
  keep the value in a static block; callers read it at once, with
  interrupts masked where a handler could call the same function.
- Constant functions cannot be imported, so each module that checks a
  layout has its own `checkedSize`; `makeBufferU64` takes a literal, so a
  `const func` checks that literal against the stack layout.
- A template foundation and its overlay must be in one module (E0107
  otherwise), so each board module declares both.

## Error handling

No exceptions: `spawnTask` returns `Result[int, SpawnError]` (the table is
full, or idle priority asked for), and `runKernel` handles the demo's
spawns with `attempt` in a `try`/`catch Err(...)`. Bugs and faults end in
`unreachable`, which `panic = "custom"` turns into a call to the board's
`@panic_handler`: it prints the source position, then any CPU fault and
any stack overflow the kernel recorded, and stops QEMU with status 2.

## Determinism

The demo's logic is a function of ticks: sleeps use absolute deadlines,
normal tasks are never preempted, and wake-ups at one tick are ordered.
What remains is time itself: with QEMU's clock following the host, a tick
can fall in the middle of a burst of switches if the host is slow (QEMU
translating code the first time it runs is enough on aarch64). The boot
tests therefore run QEMU with `-icount shift=3,sleep=off`: the guest's
clock advances 8 ns per instruction, every interrupt lands at the same
instruction on every run, and the transcript is exact. Keys still arrive
whenever the host types them; ticks after the demo, the switch and
preemption counts and the counter's numbers are masked by tests/boot.sh.

## Testing

- `make check`: Stage0 type-checks all four entry files (and the lock
  order).
- Self-test images (`boards/selftest-*`): 11 tests with `debug.assert_fs`,
  booted; QEMU's status says whether all passed.
- `make boot` (`tests/boot.sh`): six cases. The demo with `t`, `p`, `x`,
  `q`, and the overflow with `o`, on each CPU, plus the two self-tests;
  transcripts and exit statuses are compared with `tests/expected/`.

## Differences from the roadmap

- The roadmap's generic `Queue[T]` is a generic class rather than a
  generic struct (Stage0 rejects the buffer field in a generic struct). A
  generic struct, `Stamped[T]`, carries the trace's entries instead.
- Preemption is by priority: the timer takes the CPU from the background
  task whenever a normal task wakes, on both CPUs. Normal tasks share the
  CPU cooperatively; time slicing among them would make the transcript
  depend on how much work fits in a tick.
- aarch64, which the roadmap leaves optional, is included and tested,
  preemption included.
