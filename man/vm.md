## DESCRIPTION

Create and run virtual machines: arm64 guests in QEMU, as UTM runs them
on a Mac. Each machine is a directory, `~/VMs/NAME`, with its settings
(`vm.toml`) and its disk (`disk.qcow2`, which grows as the guest writes
to it). QEMU is the `qemu` app: install it first with
`sudo app install qemu`.

A machine runs headless, with UEFI firmware, a virtio disk, a CD while
`iso` is set (booted first), user-mode networking (the guest reaches the
network and this machine, at 10.0.2.2), and its serial port as its
console. It runs as you, and keeps running when the terminal that
started it closes. Its console keeps the latest 128 KB of output:
`vm console` shows the end of it and follows, `vm log` prints it.

With `/dev/kvm` the guest runs at the CPU's speed. Lepton has it when it
was booted with nested virtualization (an Apple M3 or later, and
`mix lepton.qemu --nested`); otherwise QEMU emulates the CPU, many times
slower.

## COMMANDS

- `list` (or nothing): your machines, running or stopped.
- `create NAME [-m MB] [-c CPUS] [-s SIZE] [-i ISO] [-f HOST:GUEST]`:
  make one, with 2048 MB, 2 CPUs and a 16G disk unless told otherwise,
  booting ISO; `-f` forwards a TCP port of this machine (on 127.0.0.1)
  to the guest.
- `start NAME [-c]`: start it; `-c` attaches its console too.
- `stop NAME [-f]`: press its power button (the guest shuts down);
  `-f` ends it at once.
- `console NAME`: its serial console. `C-]` detaches; the machine keeps
  running.
- `log NAME`: what its console printed lately.
- `info NAME`: its settings and state.
- `set NAME KEY=VALUE...`: change `memory`, `cpus`, `iso` (empty for no
  CD) or `forward` (comma-separated `HOST:GUEST`), from its next start.
- `delete NAME`: remove a stopped machine and its disk.

## EXAMPLES

    sudo app install qemu
    vm create test -m 2048 -i ~/lepton.iso
    vm start test -c
    vm set test iso= forward=2222:22
    vm stop test

## FILES

- `~/VMs/NAME/vm.toml`, `~/VMs/NAME/disk.qcow2`: a machine.
- `/run/lepton/vms/UID-NAME/`: a running machine's sockets.

## SEE ALSO

app(1), https://trylepton.app/docs/virtual-machines.html
