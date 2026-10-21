# loup-cmd-bare-sched

A task scheduler on bare metal, in [Loup](https://code-craft.ai/references/loup):
seven tasks on their own stacks, switched by a naked context switch, with
semaphores, ranked mutexes, sleeping on the timer, and a background task
that the timer interrupt preempts. Two producers and a consumer share a
bounded queue, a ticker sleeps on timer ticks, a counter spins at
background priority, and a monitor prints the task table and the recorded
schedule over the serial port. On x86-64 (QEMU `pc`) and AArch64 (QEMU
`virt`).

Part of the **loup-cmd** series of example applications: classic Linux and
Windows commands, and projects for each Loup execution mode, each in its own
repository under [myronccai](https://github.com/myronccai?tab=repositories&q=loup-cmd).
This one is `freestanding` Loup (`.lpfree`), booted under QEMU.

## Requirements

- Linux x86-64 (freestanding images are built on Linux only).
- [Loup Lite](https://github.com/code-craft-ai-company/loup-releases) 1.26.0
  or later; see [Installing Loup Lite](#installing-loup-lite).
- `make`, `clang`, `ld.lld` and QEMU for both architectures. On Ubuntu:

  ```sh
  sudo apt-get install clang lld qemu-system-x86 qemu-system-arm
  ```

## Installing Loup Lite

This example is built and tested with **Loup Lite**, the free public build of
the Loup toolchain from [Code Craft AI](https://code-craft.ai), meant for
education and training. Code Craft AI publishes the official builds,
installers and signed checksums at
**<https://github.com/code-craft-ai-company/loup-releases>**, for Linux
(x86-64, arm64), macOS (Apple silicon, Intel) and Windows (x86-64).

Linux and macOS:

```sh
curl -fsSL https://github.com/code-craft-ai-company/loup-releases/releases/latest/download/loup-install.sh | sh
```

Windows (PowerShell):

```powershell
irm https://github.com/code-craft-ai-company/loup-releases/releases/latest/download/loup-install.ps1 | iex
```

The installer picks the archive for your machine, checks it against the
release's `SHA256SUMS`, unpacks it into `~/.loup`
(`%LOCALAPPDATA%\Programs\Loup` on Windows) and puts its `bin` directory on
your `PATH`; it needs no administrator rights. You get `loup`, the Stage0
compiler `loup-bootstrap` and the Wasm runtime `loup-launcher`. Open a new
shell and check:

```sh
loup --version             # loup 1.26.0 or later
```

CI installs the exact version it tests with, 1.26.0. To do the same:

```sh
curl -fsSL https://github.com/code-craft-ai-company/loup-releases/releases/download/v1.26.0/loup-install.sh | sh -s -- --version 1.26.0
```

To install by hand, download your platform's archive from the
[releases page](https://github.com/code-craft-ai-company/loup-releases/releases),
check it against `SHA256SUMS`, unpack it anywhere and add its `bin` directory to
`PATH`. The [loup-releases README](https://github.com/code-craft-ai-company/loup-releases#verify-a-download)
explains how to verify the Sigstore signature on `SHA256SUMS`.

Loup Lite leaves out Loup's cryptography library and the full set of Loup
packages; this example needs neither. Commercial use of Loup needs a
license: <https://code-craft.ai/loup/license>.

## Build and run

```sh
make check               # type-check all four images (loup-bootstrap check)
make build               # build/sched-{x86_64,aarch64}.elf, build/selftest-{x86_64,aarch64}.elf
make boot                # boot them under QEMU, type keys, compare with tests/expected/
make ci                  # check, build, boot
make run                 # the x86_64 scheduler on this terminal; q quits
make run ARCH=aarch64    # the same on aarch64
```

`make build` runs `loup build --target freestanding --arch ARCH -o
build/IMAGE-ARCH.elf DIR` for each image, where `DIR` holds its manifest
(the root for the x86_64 scheduler, `boards/...` for the others);
[`scripts/qemu.sh`](scripts/qemu.sh) has the QEMU command lines. The
serial port is connected with `-chardev stdio,signal=off`, so every key,
Ctrl-C included, goes to the kernel.

`make check` prints one `E_INTERRUPT_SAFE_VIOLATION` warning per interrupt
handler, "marshals a struct by value": the frame parameter is a `borrow`,
as the language prescribes, and Loup 1.26.0 reports it anyway. It is
expected and does not fail the check.

## Usage

The kernel brings the board up, starts seven tasks and runs the demo for
110 ticks of 10 ms; then the monitor waits for keys. On x86-64:

```text
$ scripts/qemu.sh x86_64 build/sched-x86_64.elf
loup-cmd-bare-sched 0.1.0 on x86_64 (QEMU pc)
cpu: IDT loaded, 7 gates
pic: IRQs at vectors 32-47, timer and COM1 unmasked
com1: receive interrupt on
sched: 7 tasks on 16 KiB stacks; the timer preempts the background task
pit: 100 Hz (divisor 11932)
prod-a: put 1 (queue 1/4)
prod-b: put 10 (queue 2/4)
cons: got 1 (queue 1/4), sum 1
prod-a: put 2 (queue 2/4)
prod-b: put 20 (queue 3/4)
prod-a: put 3 (queue 4/4)
cons: got 10 (queue 3/4), sum 11
prod-b: put 30 (queue 4/4)
cons: got 2 (queue 3/4), sum 13
prod-a: put 4 (queue 4/4)
cons: got 20 (queue 3/4), sum 33
prod-b: put 40 (queue 4/4)
monitor at tick 12: 7 tasks, 2 queued to run
  id  task     priority    state                         runs
   0  idle     idle        ready                            0
   1  monitor  normal      running                          3
   2  prod-a   normal      blocked on semaphore free        5
   3  prod-b   normal      blocked on semaphore free        5
   4  cons     normal      blocked on mutex console         5
   5  ticker   normal      sleeping until tick 25           1
   6  counter  background  ready                            4
  mutexes: items held by cons; console held by monitor, 1 wait so far
cons: got 3 (queue 3/4), sum 36
prod-a: put 5 (queue 4/4)
...
```

At tick 12 the monitor and the consumer wake together. The monitor prints
the table while it holds the console lock and yields after each row; the
consumer runs, takes an item under the items lock, and then blocks on the
console lock, which is what the table shows. The producers wait for room
on the semaphore `free`, the ticker sleeps until tick 25, and the counter
is ready whenever nothing else is. The demo ends with the sum of all twelve
items, 231. Then `p` prints the table again and `q` stops the machine:

```text
demo finished at tick 110: 12 items consumed, sum 231
keys: p task table, t schedule trace, o overflow a stack, q quit
tasks at tick 241: 7 tasks, 1 queued to run
  id  task     priority    state                         runs
   0  idle     idle        ready                            0
   1  monitor  normal      running                          6
   2  prod-a   normal      done                             7
   3  prod-b   normal      done                             7
   4  cons     normal      done                            14
   5  ticker   normal      done                             5
   6  counter  background  ready                           19
  mutexes: items free; console held by monitor, 1 wait so far
quit at tick 292: 60 switches, 20 preemptions, counter at 236611250
QEMU exit status 33
```

`t` replays the schedule from the `debug.recording` trace: every switch to
a normal-priority task, grouped by tick. The consumer's three-tick rhythm,
the producers taking turns at the room it leaves, and the monitor and the
consumer passing the CPU back and forth at tick 12 are all there:

```text
schedule, from the debug.recording trace:
  tick   0: monitor prod-a prod-b cons ticker prod-a prod-b prod-a
             prod-b prod-a
  tick   3: cons prod-b
  tick   6: cons prod-a
  tick   9: cons prod-b
  tick  12: monitor cons monitor cons prod-a
  tick  15: cons prod-b
  tick  18: cons prod-a
  tick  21: cons prod-b
  tick  24: cons
  tick  25: ticker
  tick  27: cons
  tick  30: cons
  tick  33: cons
  tick  36: cons
  tick  50: ticker
  tick  60: monitor
  tick  75: ticker
  tick 100: ticker
  tick 110: monitor
  tick 241: monitor
  39 switches to normal-priority tasks
```

`o` starts a task that recurses past the end of its stack. Its frames land
in the guard below the stack, and the scheduler finds the guard written the
next time the task gives up the CPU (here on AArch64):

```text
$ scripts/qemu.sh aarch64 build/sched-aarch64.elf
loup-cmd-bare-sched 0.1.0 on aarch64 (QEMU virt)
cpu: vectors at 0x40080800 (VBAR_EL1)
gic: GICv2 on, INTID 27 (virtual timer) and 33 (PL011) enabled
pl011: receive interrupt on
sched: 7 tasks on 16 KiB stacks; the timer preempts the background task
timer: 100 Hz (625000 counts of 62500000 Hz)
...
keys: p task table, t schedule trace, o overflow a stack, q quit
monitor: started hog as task 7, which recurses past its 16 KiB stack
hog: deep enough to write into the guard below its stack; yielding
PANIC: reached an `unreachable` expression at kernel/sched.lpfree:144
  stack overflow: task 7 (hog) wrote past the end of its 16 KiB stack, into its guard
QEMU exit status 2
```

### Keys

| Key | What it does |
|---|---|
| `p` | the task table: id, name, priority, state, how many times the task got the CPU, and who holds each mutex |
| `t` | the schedule so far, from the trace |
| `o` | start `hog`, which recurses until it writes into its stack guard; the kernel panics |
| `q` | the tick, the switch and preemption counts and the counter's value; QEMU exits |
| Enter | nothing |

Any other key prints a one-line reminder of these. Keys typed during the
demo are kept (up to eight) and answered when it is over.

### Exit statuses

| Event | Status | QEMU exit status, x86-64 | QEMU exit status, AArch64 |
|---|---|---|---|
| `q`, or every self-test passed | 0 | 33 | 0 |
| a self-test failed | 1 | 35 | 1 |
| panic (a stack overflow, a fault) | 2 | 37 | 2 |

x86-64 writes `0x10 | status` to `isa-debug-exit`, which makes QEMU exit
with `(value << 1) | 1`; AArch64 passes the status to semihosting
`SYS_EXIT`.

## What this example shows

| Feature | Where |
|---|---|
| A naked context switch with `@callconv("sysv64")` / `@callconv("aapcs64")`, every assembly line commented; the task entry it returns into the first time | `switchContext`, `taskEntry` in [`source/x86/context.lpfree`](source/x86/context.lpfree), [`source/arm/context.lpfree`](source/arm/context.lpfree) |
| A new task's first frame: a `@repr(C)` (and on AArch64 `@align(16)`) `SwitchFrame` built with `PartialInit`, its size and alignment checked by a `const func`, written with `bufSetU64` | `newTaskFrame` in the same files |
| `@lockOrder(40) synchronized class RunQueue`; ranked mutex classes `@lockOrder(20) ItemsLock` and `@lockOrder(30) ConsoleLock`: taking them in the wrong order does not compile | [`source/kernel/sched.lpfree`](source/kernel/sched.lpfree), [`source/kernel/sync.lpfree`](source/kernel/sync.lpfree) |
| Template composition: `template foundation X86Cpu implements Platform` for the CPU and `template overlay QemuPc onto X86Cpu` for the machine, in one module (likewise `Arm64Cpu` and `QemuVirt`) | [`source/x86/board.lpfree`](source/x86/board.lpfree), [`source/arm/board.lpfree`](source/arm/board.lpfree) |
| An interface between the kernel and the boards, kept in a module variable | [`source/kernel/platform.lpfree`](source/kernel/platform.lpfree) |
| A generic class `Queue[T]` over a fixed `buffer[T, 8]`, used as `Queue[uint8]` (ready queues, keys) and `Queue[uint64]` (the producers' queue); a generic struct `Stamped[T]` for the trace | [`source/kernel/queue.lpfree`](source/kernel/queue.lpfree) |
| A generic enum `TaskState[W]` (blocked on a `W`), with `Wait` for the reasons | [`source/kernel/tasks.lpfree`](source/kernel/tasks.lpfree) |
| Preemption from interrupt handlers: `@interrupt` handlers acknowledge, wake tasks and switch away; the interrupted task finishes its handler when it is resumed | `isrTimer`, `isrIrq`, `preemptIfNeeded` |
| `@interruptSafe` call chains from the handlers into the scheduler | `clockTick`, `keyArrived`, `dispatch`, ... |
| `with (g = InterruptGuard.disable())` in every semaphore and mutex operation; `irqSaveDisable()`/`irqRestore()` around every task-side switch | [`source/kernel/sync.lpfree`](source/kernel/sync.lpfree), [`source/kernel/sched.lpfree`](source/kernel/sched.lpfree) |
| `onstack`: the batch two producers build in the same function at the same time (a plain buffer local is one static block: without `onstack` prod-b's values overwrite prod-a's and the sum is 411); the console's digit buffer; the hog's recursion | [`source/demo/workers.lpfree`](source/demo/workers.lpfree), [`source/kernel/console.lpfree`](source/kernel/console.lpfree) |
| `@no_zero_locals` on the tick path and the number formatting | `clockTick`, `earliestDue`, `putDecWidth` |
| Raw memory: the stacks reserved with `makeBufferU64`, guards and frames read and written with `bufGetU64`/`bufSetU64` under `rawpoke = "unsafe-only"`, each use in an `@unsafe` function or an `unsafe(...)` region | [`source/kernel/tasks.lpfree`](source/kernel/tasks.lpfree) |
| `debug.recording`: the schedule as `nondet_timer` and `nondet_sched` records, replayed by `t`; `if const (TRACE_SCHEDULE)` compiles it out | [`source/kernel/sched.lpfree`](source/kernel/sched.lpfree) |
| `debug.assert_fs`: unit tests booted on the bare machine | [`source/selftest/tests.lpfree`](source/selftest/tests.lpfree) |
| Errors as values: `spawnTask` returns `Result[int, SpawnError]`, `?` and `attempt` with `catch Err(e)` | [`source/demo/run.lpfree`](source/demo/run.lpfree) |
| `unreachable` and `panic = "custom"`: stack overflows and CPU faults reported by the board's `@panic_handler` | `stackOverflow`, `kernelPanic` |
| Device code: 8259 remap, 8254 PIT, 16550 receive interrupt, IDT; GICv2, the generic timer's compare value, PL011 (`Volatile[uint32, Little]`) | [`source/x86/`](source/x86), [`source/arm/`](source/arm) |
| Deterministic boot tests: QEMU's `-icount` ties the guest's clock to its instructions | [`tests/boot.sh`](tests/boot.sh) |

A deadlock by lock nesting cannot be written here. Taking the console lock
before the items lock in the consumer gives:

```text
$ loup-bootstrap check --format short
source/demo/workers.lpfree:129:9: error: E_LOCK_ORDER_ACQUIRE_VIOLATION: acquiring lock with rank 20 while lock with rank 30 is already held — lock ranks must be strictly ascending
```

### How it is put together

Every task but idle (the boot context) has a 16 KiB stack above an 8 KiB
guard. A task that is not running is just its saved stack pointer. Tasks of
the same priority switch only when they yield, sleep, block or end; a
normal task that becomes ready preempts the background counter at once,
from inside the interrupt that woke it. Sleeps are absolute ticks, sleepers
due at the same tick wake in the order of their deadlines and ids, and
semaphores and mutexes hand over to the task that has waited longest, so
the demo prints the same thing on every run.
[specs/bare-sched/design.md](specs/bare-sched/design.md) has the details,
including the Loup 1.26.0 limits that shaped the code.

## Differences from the roadmap

- `Queue[T]` is a generic class, not a generic struct: Loup 1.26.0's Stage0
  checker rejects a `buffer[T, N]` field in a generic struct
  (`E_STRUCT_CLASS_FIELD`). The trace's `Stamped[T]` is the generic
  struct.
- The timer preempts by priority (the background counter gives way to any
  normal task) on both CPUs; tasks of the same priority are cooperative.
  Time slices among them would make the transcript depend on how much work
  fits in 10 ms.
- The aarch64 board, which the roadmap leaves optional, is included and
  tested, preemption included.
- The boot tests run QEMU with `-icount shift=3,sleep=off`. With QEMU's
  clock following the host, a tick can fall in the middle of a burst of
  task switches on a slow host (or while QEMU translates code for the
  first time), and the recorded schedule would group them differently.
  `make run` uses the host's clock.

## Layout

```text
package.lppkg                    # x86_64 scheduler: freestanding, panic = "custom", rawpoke = "unsafe-only"
boards/aarch64/package.lppkg     # aarch64 scheduler
boards/selftest-*/package.lppkg  # the self-test images
linker/x86_64.ld                 # 1 MiB; boot page tables; .idt on its own page
linker/aarch64.ld                # 0x40080000; vector table 2 KiB aligned
source/main_*.lpfree             # the schedulers' kernelMain
source/selftest_*.lpfree         # the self-tests' kernelMain
source/kernel/                   # platform interface, console, Queue[T], task table, scheduler, sync
source/demo/                     # the tasks, the monitor, start-up
source/x86/                      # board (Platform, panic, PVH entry), context switch, IDT, handlers, 8259/8254, COM1
source/arm/                      # board (Platform, panic, entry), context switch, vectors, GICv2, timer, PL011
source/selftest/                 # unit tests run by the self-test images
scripts/qemu.sh                  # the QEMU command line for each CPU
tests/boot.sh                    # boot tests (make boot)
tests/expected/                  # expected transcripts
specs/bare-sched/                # requirements, design, tasks
```

[AGENTS.md](AGENTS.md) has every build and test command and the conventions
for changing the code.

## License

[MIT](LICENSE), copyright 2026 Code Craft AI LLC. The Loup skill in
[`skills/loup-programmer/`](skills/loup-programmer/) is copied from the Loup
project and is not covered by this license; it keeps the Loup project's terms.
