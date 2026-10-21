# Requirements: bare-sched

## Introduction

`bare-sched` is a task scheduler on bare metal. A kernel with no operating
system underneath runs seven tasks on their own stacks: two producers and a
consumer sharing a bounded queue, a ticker that sleeps on the timer, a
background counter that never gives up the CPU, a monitor that prints the
task table over the serial port, and the idle task. Tasks of the same
priority switch cooperatively (yield, sleep, block); the timer interrupt
preempts the background task as soon as anything else is ready. Semaphores
and mutexes block and wake tasks in arrival order, and the mutexes are
ranked so the compiler rejects any lock nesting that could deadlock. It
runs on x86-64 (QEMU `pc`) and AArch64 (QEMU `virt`), and is the scheduler
example of the loup-cmd series: it is there to show `@lockOrder` on the
synchronized run queue, a naked context switch with its calling
convention, template composition for the boards, a generic queue over a
fixed buffer, a generic enum for task states, `InterruptGuard` and
`onstack`.

## Requirements

### Requirement 1: Start-up

**User Story:** As a reader, I want the kernel to say what it set up so that
I can follow the bring-up on the console.

#### Acceptance Criteria

1. WHEN the image boots, THE kernel SHALL print
   `loup-cmd-bare-sched 0.1.0 on ARCH (MACHINE)`.
2. ON x86_64, THE board SHALL install IDT gates for the faults (#UD, #DF,
   #GP, #PF), the timer (vector 32), COM1 (vector 36) and the spurious
   IRQ 7, load the IDT, remap the 8259 pair to vectors 32-47 with only
   IRQ 0 and IRQ 4 unmasked, and enable COM1's receive interrupt, printing
   one line per step.
3. ON aarch64, THE board SHALL install the vector table in `VBAR_EL1`,
   enable the GICv2 with INTID 27 (virtual timer) and 33 (PL011), and
   enable the PL011's receive interrupt, printing one line per step.
4. THE kernel SHALL spawn the demo's six tasks, print
   `sched: 7 tasks on 16 KiB stacks; ...`, start the timer at 100 Hz as
   its last step (printing a line), unmask interrupts and give the CPU to
   the first task.
5. IF a task cannot be spawned, THE kernel SHALL print why and stop with
   the panic status.

### Requirement 2: Tasks and context switches

**User Story:** As a reader, I want each task on its own stack, so that a
task can stop anywhere in its code and resume there.

#### Acceptance Criteria

1. THE scheduler SHALL hold up to 8 tasks, task 0 being the boot context
   (idle), each other with a 16 KiB stack above an 8 KiB guard.
2. THE board SHALL switch tasks with a naked function that saves the
   callee-saved registers of the platform's calling convention on the
   running task's stack, stores its stack pointer, loads the next task's
   and restores its registers.
3. A new task SHALL start through a frame its board builds, which leads
   to an entry that unmasks interrupts and calls the task's function with
   its argument; a task whose function returns SHALL end (state `done`).
4. THE scheduler SHALL keep a task's state as ready, running,
   sleeping until a tick, blocked (on a semaphore, a mutex or input) or
   done.

### Requirement 3: Scheduling

**User Story:** As a user, I want a predictable schedule so that the same
program prints the same thing on every run.

#### Acceptance Criteria

1. THE scheduler SHALL run the oldest ready task of the highest priority
   (normal, then background, then idle).
2. Tasks of the same priority SHALL only lose the CPU by yielding,
   sleeping, blocking or ending.
3. WHEN the timer interrupt makes a task ready whose priority is higher
   than the running task's, THE scheduler SHALL switch to it before the
   interrupt returns (preemption); the preempted task SHALL resume later
   where it was interrupted.
4. WHEN the clock reaches a sleeping task's tick, THE scheduler SHALL make
   it ready; tasks due at the same tick SHALL become ready in the order of
   their ticks, then of their ids.
5. WHEN nothing is ready, THE idle task SHALL wait for an interrupt
   (`hlt`, `wfi`).
6. WHEN a task gives up the CPU and the guard below its stack no longer
   holds its pattern, THE scheduler SHALL panic and report the task.

### Requirement 4: Synchronization

**User Story:** As a task author, I want semaphores and mutexes that cannot
deadlock by nesting so that tasks can share data safely.

#### Acceptance Criteria

1. A semaphore SHALL count units; `down` SHALL take one or block the task
   until `up` hands it one; `up` SHALL wake the task that has waited
   longest, else add to the count.
2. A mutex SHALL have one owner; `acquire` SHALL block while another task
   owns it; `release` SHALL hand it to the task that has waited longest.
   Locking a mutex twice, or releasing one the task does not own, SHALL
   panic.
3. Each mutex SHALL carry a rank (items 20, console 30) and the run queue
   rank 40; code that takes a lock of a lower rank while holding a higher
   one SHALL fail to compile.
4. Every scheduler and synchronization operation SHALL run with
   interrupts masked.

### Requirement 5: The demo

**User Story:** As a user, I want to watch the scheduler at work and ask it
questions from the serial console.

#### Acceptance Criteria

1. THE producers SHALL put 1-6 and 10-60 into a queue of 4, yielding after
   each item; THE consumer SHALL take one item every 3 ticks until it has
   12, printing each with the queue length and the running sum, and finish
   with the sum 231.
2. THE ticker SHALL print the tick at 25, 50, 75 and 100.
3. THE monitor SHALL print the task table (id, name, priority, state, runs,
   and the mutexes' owners) at ticks 12, 60 and 110, yielding after every
   row while holding the console lock, then print the demo's result and the
   keys.
4. THE counter SHALL count at background priority without ever yielding.
5. WHEN the user types `p`, THE monitor SHALL print the task table; `t`,
   the schedule recorded so far (each switch to a normal-priority task,
   grouped by tick); `o`, start a task that recurses past its stack; `q`,
   print the tick, switch and preemption counts and the counter's value,
   then stop the machine; any other key except Enter, a one-line hint.

### Requirement 6: Testing

**User Story:** As a maintainer, I want every image booted in CI so that a
change that breaks the scheduler on either CPU fails the build.

#### Acceptance Criteria

1. A self-test image per CPU SHALL run unit tests of the queue, the console
   formatting, the task states, the wake-up order, the priorities, the
   semaphore count and the stack guards, and stop with status 0 (all
   passed) or 1.
2. `make boot` SHALL boot the scheduler under QEMU, wait for the demo,
   type `t`, `p`, `x` and `q` and compare the transcript and QEMU's exit
   status; boot it again and type `o`; boot each self-test image.
3. THE boot tests SHALL run QEMU with `-icount`, so that the guest's clock
   follows its instructions and the transcript does not depend on the
   host's speed; values that depend on when keys are typed SHALL be masked.
4. THE panic output (with its source line) SHALL be compared like the rest.
