## DESCRIPTION

Install Lepton from the running ISO onto a disk, so that your files,
apps and accounts are kept, or upgrade an installed Lepton to the
release you booted. Only root may install: on the live ISO you are
root; on an installed system use `sudo`.

`lepton-install` asks which disk to use (unless DISK is named), shows
what is on it, and asks you to confirm. On a disk without Lepton it
installs, then asks you to create your user account (a name and a
password), which may use `sudo`. On a disk that has Lepton it asks
whether to upgrade (replace Lepton, keeping everything else) or erase
it and install from scratch.

A disk that has other systems on it keeps them: Lepton goes into an
empty partition or free space, never into EFI, Apple or Microsoft
system partitions or one with files in it. Name a PARTITION to choose
the place yourself.

## OPTIONS

- `-y`, `--yes`: do not ask: install, or upgrade an existing Lepton.
- `--upgrade`: upgrade, without asking.
- `--erase`: erase the disk and install from scratch (asks to confirm
  unless `-y`).
- `--iso FILE`: install or upgrade from a downloaded ISO file instead of
  the booted ISO. On an installed system this is how to upgrade: then
  `sudo reboot`.
- `-u NAME`: the user account to create.
- `--password-stdin`: read the account's password from standard input.

## EXAMPLES

    lepton-install
    echo PASSWORD | lepton-install -y -u alice --password-stdin /dev/vda
    lepton-install /dev/vda3
    sudo lepton-install --iso ~/Downloads/lepton.iso

## SEE ALSO

lsblk(1), useradd(1), sudo(1), https://trylepton.app/docs/getting-started.html
