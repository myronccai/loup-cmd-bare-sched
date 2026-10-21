#!/usr/bin/env bash
# Boot a loup-cmd-bare-sched image under QEMU with the guest's serial port
# on this script's standard input and output. Every key, Ctrl-C included,
# goes to the kernel (q quits the scheduler). QEMU exits when the image
# reports its status: isa-debug-exit on x86_64, semihosting on aarch64.
#
# usage: scripts/qemu.sh ARCH IMAGE [QEMU-ARGS...]
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: scripts/qemu.sh ARCH IMAGE [QEMU-ARGS...]" >&2
    exit 2
fi
arch=$1
image=$2
shift 2

common=(-display none -monitor none -nic none -no-reboot
    -chardev stdio,id=serial0,signal=off -serial chardev:serial0)

case "$arch" in
    x86_64)
        exec qemu-system-x86_64 -machine pc -m 128M "${common[@]}" \
            -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
            -kernel "$image" "$@"
        ;;
    aarch64)
        exec qemu-system-aarch64 -machine virt -cpu cortex-a53 -m 256M "${common[@]}" \
            -semihosting -kernel "$image" "$@"
        ;;
    *)
        echo "qemu.sh: unknown ARCH '$arch' (x86_64 or aarch64)" >&2
        exit 2
        ;;
esac
