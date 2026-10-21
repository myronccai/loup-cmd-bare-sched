# Check, build and boot the bare-metal images of loup-cmd-bare-sched.
#
# Four images: the scheduler and the self-test, each for x86_64 (QEMU pc)
# and aarch64 (QEMU virt). The x86_64 scheduler's manifest is package.lppkg
# at the root; the others are under boards/. On Linux x86-64 `loup` is the
# self-hosted driver, which builds images; `loup-bootstrap` (Stage0)
# type-checks them.

LOUP           ?= loup
LOUP_BOOTSTRAP ?= loup-bootstrap
BUILD_DIR      ?= build
ARCH           ?= x86_64
IMAGES         := $(BUILD_DIR)/sched-x86_64.elf $(BUILD_DIR)/sched-aarch64.elf \
                  $(BUILD_DIR)/selftest-x86_64.elf $(BUILD_DIR)/selftest-aarch64.elf
BOARDS         := boards/aarch64 boards/selftest-x86_64 boards/selftest-aarch64
SOURCES        := package.lppkg $(wildcard boards/*/package.lppkg) \
                  $(wildcard linker/*.ld) $(shell find source -name '*.lpfree')

# The directory holding an image's manifest: build/IMAGE-ARCH.elf comes
# from boards/IMAGE-ARCH, except the x86_64 scheduler (the root) and the
# aarch64 one (boards/aarch64).
manifest_dir = $(if $(filter sched-x86_64,$(1)),.,$(if $(filter sched-aarch64,$(1)),boards/aarch64,boards/$(1)))
arch_of = $(lastword $(subst -, ,$(1)))

.PHONY: all check build boot run ci clean

all: build

# Type-check every image's entry file and the modules it imports. Each
# interrupt handler draws an expected "marshals a struct by value"
# warning (see the README).
check:
	$(LOUP_BOOTSTRAP) check --no-color
	for b in $(BOARDS); do (cd $$b && $(LOUP_BOOTSTRAP) check --no-color) || exit 1; done

# All four images (needs Linux x86-64, clang and ld.lld).
build: $(IMAGES)

# `loup build` skips a build whose fingerprint (next to the image) matches,
# and for a manifest under boards/ the fingerprint does not cover the
# sources in ../../source: it is removed whenever make decides to rebuild.
$(BUILD_DIR)/%.elf: $(SOURCES)
	@mkdir -p $(BUILD_DIR)
	@rm -f $@.loupbuild.fp
	$(LOUP) build --target freestanding --arch $(call arch_of,$*) -o $@ $(call manifest_dir,$*)

# End-to-end: boot every image under QEMU, wait for the demo, type keys,
# and compare the transcripts and exit statuses with tests/expected/.
boot: $(IMAGES)
	bash tests/boot.sh $(BUILD_DIR)

# Boot the scheduler on this terminal, e.g. `make run ARCH=aarch64`. Keys
# go to the kernel; q quits.
run: $(BUILD_DIR)/sched-$(ARCH).elf
	-scripts/qemu.sh $(ARCH) $<

# Everything CI runs.
ci: check build boot

clean:
	rm -rf $(BUILD_DIR) .temp boards/*/.temp
