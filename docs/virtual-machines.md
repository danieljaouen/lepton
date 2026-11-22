---
title: Virtual machines (vm)
order: 12
section: system
summary: Run arm64 virtual machines inside Lepton with QEMU, at full speed with nested virtualization, and test Lepton inside Lepton.
---

# Virtual machines

Lepton runs virtual machines with **QEMU**, Alpine's build, installed on
demand. Machines are arm64 guests (Lepton itself, or any arm64 Linux),
run headless on their serial consoles, much as UTM runs them on a Mac.

```sh
sudo app install qemu                     # QEMU, qemu-img, UEFI firmware (about 31 MB)
vm create test -i ~/lepton.iso            # a machine booting Lepton's ISO
vm start test -c                          # start it, and attach its console
```

## At full speed: nested virtualization

A machine runs at the CPU's speed when Lepton has **KVM** (`/dev/kvm`).
Lepton's kernel has KVM, but it needs the CPU's virtualization mode,
which Lepton only gets when it runs in a VM that passes it on: *nested
virtualization*. Macs with an M3 or later chip have it, on macOS 15 or
later.

- With `mix lepton.qemu`, add `--nested`. It boots Lepton's kernel
  directly, because the UEFI firmware hangs in that mode under macOS's
  Hypervisor.framework. The clock is then set by `ntpd` a few seconds
  after the network comes up.
- In UTM, nested virtualization needs the QEMU machine option
  `virtualization=on` and booting from the kernel image (`vmlinuz`,
  `initrd.img`, and the command line in `grub.cfg`, all on the ISO).

Without KVM, QEMU emulates the CPU: machines still run, many times
slower. `vm info NAME` says which.

## Managing machines

| Command | What it does |
|---|---|
| `vm` | list your machines |
| `vm create NAME [-m MB] [-c CPUS] [-s SIZE] [-i ISO] [-f HOST:GUEST]` | make one (2048 MB, 2 CPUs, a 16G disk by default) |
| `vm start NAME [-c]` | start it (`-c`: attach its console) |
| `vm console NAME` | its serial console; `C-]` detaches, the machine keeps running |
| `vm log NAME` | what its console printed lately |
| `vm stop NAME [-f]` | press its power button (`-f`: end it at once) |
| `vm set NAME KEY=VALUE...` | change `memory`, `cpus`, `iso`, `forward` |
| `vm info NAME` / `vm delete NAME` | settings and state / remove it |

A machine is a directory, `~/VMs/NAME`, with its settings in `vm.toml`
and its disk in `disk.qcow2`. The disk grows as the guest writes to it.
Machines run as you, and keep running after the terminal that started
them closes.

Each machine gets UEFI firmware, a virtio disk, the CD (booted first,
while `iso` is set: `vm set NAME iso=` takes it out after installing),
user-mode networking, and a serial console. The guest reaches the
network, and this machine at 10.0.2.2. To reach the guest, forward a
port: with `vm set test forward=2222:22`, `ssh -p 2222 root@localhost`
reaches the guest's `sshd`.

## Testing Lepton inside Lepton

With QEMU installed, `mix lepton.qemu` works in a checkout of Lepton's
source, in Lepton. It finds QEMU on the path of Lepton's `mix`, and of
[Claude Code](claude-code.html)'s bash:

```sh
git clone https://github.com/danieljaouen/lepton && cd lepton
mkdir -p out && curl -o out/lepton.iso https://github.com/danieljaouen/lepton.iso/releases/latest/download/lepton.iso
mix compile
mix lepton.qemu --test          # the self-test suite, in a VM inside Lepton
```

With KVM, the suite takes about as long as it does on the Mac.

## Limits

- No display: machines run on their serial consoles. Lepton as a guest
  works fully there; a desktop guest's screen isn't shown.
- arm64 guests only (`qemu-system-aarch64`).
- `vm` is Lepton's own command, so Claude Code can't run it. It can run
  QEMU itself, and `mix lepton.qemu`.

<!-- commands: vm -->
