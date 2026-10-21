# AGENTS.md

This repository is `loup-cmd-bare-sched`, a task scheduler on bare metal,
in the loup-cmd series of Loup example applications. It is `freestanding`
Loup (`.lpfree`): no operating system, no heap, no exceptions. It is built
for two boards (x86-64 on QEMU `pc`, AArch64 on QEMU `virt`), each as a
scheduler image and a self-test image, and tested by booting the images
under QEMU, waiting for their output and typing keys.

## Skills

| Skill | Location | Use it when |
|-------|----------|-------------|
| `loup-programmer` | [skills/loup-programmer/SKILL.md](skills/loup-programmer/SKILL.md) | Writing, reviewing, debugging or explaining Loup code: `.lpscr`, `.loup`, `.lphc`, `.lpweb` or `.lpfree` source files, `.lppkg` manifests, `@mode(...)` directives, or the `loup` / `loup-bootstrap` commands. |

Read `skills/loup-programmer/SKILL.md` and
`skills/loup-programmer/references/freestanding.md` before writing or
changing any Loup code in this repository. Load the other references only as
needed.

## Code layout

```text
.
├── package.lppkg                    # x86_64 scheduler: [build] entry/arch/panic, [linker], [freestanding] (rawpoke = "unsafe-only")
├── boards/
│   ├── aarch64/package.lppkg        # aarch64 scheduler; paths relative to its directory
│   ├── selftest-x86_64/package.lppkg
│   └── selftest-aarch64/package.lppkg
├── linker/
│   ├── x86_64.ld                    # 1 MiB; .text.boot first; .note.Xen; .idt page-aligned; boot page tables
│   └── aarch64.ld                   # 0x40080000; .text.boot first; .text.vectors 2 KiB aligned
├── source/                          # all Loup code; modules import each other by path from here
│   ├── appinfo.lpfree               # APP_NAME, APP_VERSION, STATUS_*
│   ├── main_x86_64.lpfree           # kernelMain of the x86_64 scheduler
│   ├── main_aarch64.lpfree          # kernelMain of the aarch64 scheduler
│   ├── selftest_x86_64.lpfree       # kernelMain of the x86_64 self-test
│   ├── selftest_aarch64.lpfree      # kernelMain of the aarch64 self-test
│   ├── kernel/                      # shared by every image
│   │   ├── platform.lpfree          # interface Platform: what a board does for the scheduler
│   │   ├── console.lpfree           # attach(put), puts, putDec, putDecWidth, putHex, putCell
│   │   ├── queue.lpfree             # class Queue[T] over a buffer[T, 8]
│   │   ├── tasks.lpfree             # Wait, TaskState[W], the task table, stacks and guards
│   │   ├── sched.lpfree             # RunQueue (@lockOrder(40)), dispatch, clock, preemption, yield/sleep/block/spawn, trace
│   │   └── sync.lpfree              # Semaphore; mutexes, ItemsLock (20), ConsoleLock (30)
│   ├── demo/                        # the scheduler images' tasks
│   │   ├── run.lpfree               # runKernel(board): banner, bring-up, spawn, start
│   │   ├── workers.lpfree           # producers, consumer, ticker, counter, hog
│   │   └── monitor.lpfree           # task table, schedule trace, keys
│   ├── x86/                         # board.lpfree (X86Cpu + QemuPc, panic handler, PVH entry), context, idt, isr, chipset, com1, ports, qemu
│   ├── arm/                         # board.lpfree (Arm64Cpu + QemuVirt, panic handler, entry), context, vectors, gic, timer, pl011, qemu
│   └── selftest/tests.lpfree        # the unit tests and their runner
├── scripts/qemu.sh                  # the QEMU command line for each CPU
├── tests/
│   ├── boot.sh                      # boot tests: wait:/send: steps, -icount, transcripts and exit statuses
│   └── expected/                    # expected transcripts (key-time ticks and counts masked as N)
├── specs/bare-sched/                # requirements.md, design.md, tasks.md
├── skills/loup-programmer/          # the Loup skill and its references
├── .github/workflows/ci.yml         # installs lld, QEMU and Loup, runs `make ci`, uploads the images
└── build/                           # build output (git-ignored)
```

## Build, run and test

Prerequisites: Linux x86-64, Loup 1.26.0 (`loup` and `loup-bootstrap` on
`PATH`), `make`, `clang`, `ld.lld`, `qemu-system-x86_64` and
`qemu-system-aarch64`.

Loup Lite comes from <https://github.com/code-craft-ai-company/loup-releases>;
[README.md](README.md#installing-loup-lite) has the install commands.

| Task | Command | Notes |
|------|---------|-------|
| Type-check | `make check` | all four images; one expected frame warning per interrupt handler |
| Build | `make build` | `build/sched-{x86_64,aarch64}.elf`, `build/selftest-{x86_64,aarch64}.elf` |
| Build one image | `make build/sched-aarch64.elf` | |
| Boot tests | `make boot` | `tests/boot.sh`: six cases, a few seconds (QEMU runs with `-icount`) |
| Refresh expected transcripts | `UPDATE=1 bash tests/boot.sh` | then read `git diff tests/expected` before committing |
| Use the scheduler | `make run` / `make run ARCH=aarch64` | keys go to the kernel; `q` quits |
| Everything CI runs | `make ci` | check, build, boot |
| Clean | `make clean` | removes `build/` and the `.temp/` directories |

Run `make ci` before reporting a change as done. `loup-bootstrap check`
accepts things the freestanding back ends reject or miscompile, so only a
boot proves a change. Do not call `loup check` on Linux x86-64 (the
self-hosted driver refuses it).

## Making a change

1. Update the spec in `specs/bare-sched/`.
2. Change the code under `source/` (or `linker/`).
3. Add a self-test to `source/selftest/tests.lpfree` for logic that can be
   checked without switching tasks, or a case at the end of
   `tests/boot.sh`.
4. Run `make build`, then `UPDATE=1 bash tests/boot.sh`, read the diff of
   `tests/expected/`, then `make ci`. The overflow transcripts contain the
   line of `unreachable` in `stackOverflow` (kernel/sched.lpfree): a line
   added above it changes them, and the README quotes them.
5. Tick the finished tasks in `specs/bare-sched/tasks.md`.

## Conventions

- Every source file is `@mode(freestanding)` with the `.lpfree` extension.
  Each board module (`x86/board.lpfree`, `arm/board.lpfree`) has the single
  `@entry` (`_start`); `_start` calls `kernelMain`, which each entry file
  defines.
- Code that differs per CPU lives in `source/x86/` and `source/arm/`;
  `source/kernel/`, `source/demo/` and `source/selftest/` must build for
  both. The kernel reaches the board only through `Platform`.
- A template foundation and its overlay stay in one module: across modules
  the 1.26.0 freestanding build fails (E0107).
- Every switch happens in `dispatch()` with interrupts masked. Task-side
  code masks with `irqSaveDisable()`/`irqRestore()` (or `InterruptGuard` in
  `kernel/sync.lpfree`); interrupt handlers are masked already. Calls into
  `RunQueue` always happen masked: its lock would deadlock against a
  handler otherwise.
- Interrupt handlers call only `@interruptSafe` functions, acknowledge
  their interrupt first and call `preemptIfNeeded()` last.
- Lock ranks: items 20, console 30, run queue 40. A new lock gets a class
  of its own with `@lockOrder(n)`.
- An aggregate local (a buffer, a struct) is one static block per function
  unless it is `onstack`: in code that two tasks can run at once, or that
  keeps the local across a yield, sleep or block, declare it `onstack`.
- Functions returning an enum with a payload or an `Option` keep the value
  in a static block: read it at once.
- Queues hold scalars, and the task table stores states as integers: a
  buffer of structs or of enums with payloads holds references in 1.26.0
  freestanding builds. `==` on enum values with a payload is always false:
  compare with `match`.
- Raw memory access (`bufGetU64`, `bufSetU64`) needs an `@unsafe` function
  or an `unsafe("...")` region (`rawpoke = "unsafe-only"`).
- A `const func` cannot be imported in 1.26.0, and Stage0's const evaluator
  refuses parenthesized expressions and imported constants as arguments:
  keep layout checks module-local.
- `make build` removes `build/*.elf.loupbuild.fp` before each image: the
  self-hosted build cache does not see changes under `source/` for the
  manifests in `boards/`.
- Sized integers (`uint8` ... `uint32`) do not wrap in 1.26.0 freestanding
  builds; compute in `uint64` and mask when wrap-around matters.
- `spawn` is a keyword: the kernel's function is `spawnTask`.
- Keep `APP_VERSION` in `source/appinfo.lpfree` equal to `version` in the
  four manifests.
- The skill documents toolchain 1.25.1; this repository targets 1.26.0. When
  they disagree, trust the toolchain's behaviour.
