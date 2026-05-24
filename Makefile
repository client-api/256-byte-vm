# =============================================================================
# 256-byte-vm — build the boot sector and convert to every common VM format.
# =============================================================================

BUILD     := build
SRC       := src/boot.asm

# Raw disk is padded to 1 MiB. The bare BIOS minimum is a single 512-byte
# sector, but SeaBIOS on Q35 (AHCI/IDE/virtio-blk) won't recognise a disk
# below ~1 MiB as bootable. 1 MiB keeps both i440fx and Q35 happy.
DISK_BYTES := 1048576

# Targets
BOOT_BIN  := $(BUILD)/boot.bin
RAW_IMG   := $(BUILD)/boot.img
QCOW2     := $(BUILD)/boot.qcow2
VDI       := $(BUILD)/boot.vdi
VMDK      := $(BUILD)/boot.vmdk
VHD       := $(BUILD)/boot.vhd
ISO       := $(BUILD)/boot.iso

VMDK_FLAT := $(BUILD)/boot-flat.vmdk

FORMATS   := $(BOOT_BIN) $(RAW_IMG) $(QCOW2) $(VDI) $(VMDK) $(VMDK_FLAT) $(VHD) $(ISO)

.PHONY: all clean check size test run run-serial run-iso help

all: $(FORMATS) ## Build every output format
	@echo
	@echo "Built artifacts:"
	@ls -la $(FORMATS)

$(BUILD):
	@mkdir -p $(BUILD)

# ---- 256-byte program -------------------------------------------------------
$(BOOT_BIN): $(SRC) | $(BUILD)
	nasm -f bin -o $@ $<
	@test "$$(stat -c %s $@)" = "256" \
	  || { echo "boot.bin must be exactly 256 bytes, got $$(stat -c %s $@)"; exit 1; }

# ---- raw bootable disk ------------------------------------------------------
# Place boot.bin at offset 0 of a zeroed 1 MiB disk, then stamp the BIOS MBR
# signature (0x55 0xAA) at offset 510 so the sector is recognised as bootable.
$(RAW_IMG): $(BOOT_BIN)
	dd if=/dev/zero of=$@ bs=1 count=0 seek=$(DISK_BYTES) status=none
	dd if=$(BOOT_BIN) of=$@ bs=1 count=256 conv=notrunc status=none
	printf '\125\252' | dd of=$@ bs=1 seek=510 count=2 conv=notrunc status=none

# ---- hypervisor formats via qemu-img ---------------------------------------
# Each format option is picked to give the smallest valid file qemu-img can
# emit; the format's own header/footer overhead is the floor.

# cluster_size=512 trims qcow2 from ~384 KiB to ~3 KiB.
$(QCOW2): $(RAW_IMG)
	qemu-img convert -f raw -O qcow2 -o cluster_size=512 $< $@

# VDI's block layout enforces a 1 MiB minimum even for a one-sector disk.
$(VDI): $(RAW_IMG)
	qemu-img convert -f raw -O vdi $< $@

# monolithicFlat emits a 512-byte descriptor ($@) referencing a separate flat
# data file (boot-flat.vmdk). qemu-img writes both with a single invocation.
$(VMDK) $(VMDK_FLAT) &: $(RAW_IMG)
	qemu-img convert -f raw -O vmdk -o subformat=monolithicFlat $< $(VMDK)

# subformat=fixed + force_size=on drops VHD from ~2 MiB to 1 KiB (one data
# sector plus the 512-byte footer required by the VHD spec).
$(VHD): $(RAW_IMG)
	qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on $< $@

# ---- bootable ISO (El Torito, no emulation) --------------------------------
# -boot-info-table is intentionally omitted: it patches bytes 8..63 of the
# boot image with disk metadata, which would overwrite our COM1 init code.
# -no-pad skips the 150 KiB trailing CD-pad sectors mkisofs adds by default.
$(ISO): $(BOOT_BIN)
	rm -rf $(BUILD)/iso-root
	mkdir -p $(BUILD)/iso-root
	cp $(BOOT_BIN) $(BUILD)/iso-root/boot.bin
	xorriso -as mkisofs \
	    -V "CLIENTAPI" \
	    -b boot.bin \
	    -no-emul-boot \
	    -boot-load-size 1 \
	    -no-pad \
	    -o $@ \
	    $(BUILD)/iso-root

# ---- sanity / inspection ----------------------------------------------------
check: $(BOOT_BIN) ## Verify size + MBR signature
	@python3 scripts/check-size.py $(BOOT_BIN)

size: $(BOOT_BIN) ## Print code+data byte count (target: <= 256)
	@python3 scripts/check-size.py $(BOOT_BIN) --short

test: $(RAW_IMG) ## End-to-end smoke test (banner + REPL + ACPI shutdown)
	@python3 scripts/repl-test.py

# ---- run targets ------------------------------------------------------------
QEMU      ?= qemu-system-x86_64
QEMU_ARGS ?= -nographic -no-reboot

run: $(RAW_IMG) ## Boot raw disk in qemu (Ctrl-A X to quit)
	$(QEMU) $(QEMU_ARGS) -drive format=raw,file=$(RAW_IMG)

run-serial: $(RAW_IMG) ## Boot raw disk with serial only
	$(QEMU) -nographic -no-reboot -serial mon:stdio \
	    -drive format=raw,file=$(RAW_IMG)

run-iso: $(ISO) ## Boot ISO in qemu
	$(QEMU) $(QEMU_ARGS) -cdrom $(ISO)

clean: ## Remove build artifacts
	rm -rf $(BUILD)

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-14s %s\n", $$1, $$2}'
