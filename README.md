# 256-byte-vm

A bootable x86 VM whose program is a single **256-byte** file (`boot.bin`).
The build step wraps it into raw, qcow2, vdi, vmdk, vhd and iso images
that boot on QEMU, Proxmox, VMware, VirtualBox, Hyper-V, and any BIOS PC.

Banner `ClientAPI` prints to BIOS video and COM1 serial. A serial REPL
echoes each typed line back **reversed** (`hello` → `olleh`). The guest
reacts to the hypervisor's ACPI power-button event — i.e. `qm shutdown`
on Proxmox — by writing `SLP_EN` to `PM1a_CNT` so the VM exits cleanly
to S5 instead of being force-killed after the shutdown timeout.

## Output formats

`make all` produces every common VM disk format from `boot.bin`:

| File                           | Format                | Use case                    |
|--------------------------------|-----------------------|-----------------------------|
| `boot.bin`                     | raw program           | dd / hexdump / `xxd`        |
| `boot.iso`                     | ISO 9660 + El Torito  | bootable CD / `qemu -cdrom` |
| `boot.qcow2`                   | QCOW2                 | Proxmox, libvirt, KVM       |
| `boot.vmdk` + `boot-flat.vmdk` | VMware monolithicFlat | VMware Workstation / ESXi   |
| `boot.vhd`                     | Microsoft VHD         | Hyper-V, Azure              |
| `boot.vdi`                     | VirtualBox VDI        | VirtualBox                  |
| `boot.img`                     | raw bootable disk     | `qemu -drive format=raw`    |

## Build

```bash
sudo apt-get install -y nasm qemu-utils xorriso
make all
```

Outputs land in `build/`.

## Run locally

```bash
make run          # boot raw disk in qemu, screen + serial multiplexed
make run-serial   # boot raw disk, serial-only
make run-iso      # boot ISO in qemu
make test         # banner + REPL + ACPI shutdown e2e
```

Quit qemu with `Ctrl-A X`.

## Use on Proxmox

### As a CD image

```bash
# Upload boot.iso to your ISO storage (e.g. local:iso) and attach.
qm create 9999 --memory 64 --net0 virtio,bridge=vmbr0 \
  --ide2 local:iso/boot.iso,media=cdrom \
  --boot order=ide2
qm start 9999
qm terminal 9999    # serial console
```

### As a disk image

```bash
qm importdisk 9999 build/boot.qcow2 local-lvm
qm set 9999 --scsi0 local-lvm:vm-9999-disk-0
qm set 9999 --boot order=scsi0
qm start 9999
qm terminal 9999
qm shutdown 9999    # ACPI power-button — guest reacts via SLP_EN
```

## Inspect

```bash
make check        # validate boot.bin size + code+data fits
make size         # one-line size report
```

```text
$ make size
222 / 256 bytes (34 free)
```

## What fits in 256 bytes

- COM1 init at 9600 8N1
- BIOS teletype output (`int 0x10` AH=0Eh)
- Serial RX poll, line buffer (80 chars), in-place reverse, echo back
- ACPI PM1a_EN write to arm the power-button event source
- ACPI PM1a_STS polling for the hypervisor shutdown request
- ACPI S5 shutdown via SLP_EN write to PM1a_CNT

## License

Apache 2.0 — see [LICENSE](LICENSE).
