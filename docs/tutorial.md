---
title: Tutorial
order: 0
summary: A guided tour of Lepton, from the first boot to the desktop, Firefox, USB devices, sound, Bluetooth and upgrades.
---

# Tutorial

This tour takes you through Lepton one step at a time, from downloading
it to the desktop, Firefox, USB drives, sound, Bluetooth and upgrading
to a new release. Each lesson has commands to try. Type them as they
are, then follow the link at the end of the lesson to the full guide.

Lines starting with `#` in the examples are comments: you don't type
them. Inside Lepton, `help` lists every command and `man COMMAND` explains
one. There's also a shorter tour you can take inside the OS itself:
`lepton-tutorial` ([its lessons](lepton-tutorial.html)).

## 1. Run Lepton

Lepton runs in a virtual machine on your Mac (it is built for Apple
silicon and other 64-bit ARM machines).

1. Download the ISO from the [home page](../#download).
2. In [UTM](https://mac.getutm.app/), create a new VM: **Virtualize →
   Linux**, choose the ISO as the boot image, and give it 2 GB of memory
   or more (4 GB for Firefox).
3. Start it. After a few seconds you're at a prompt, logged in as `root`.

```sh
neofetch            # what you're running
uname -a
ls /
```

This is the **live** system: it runs entirely in memory, so anything you
do is gone when it stops. The next lesson keeps it.

More: [Getting started](getting-started.html).

## 2. Install it on a disk

1. Stop the VM and add a disk: **Drives → New → VirtIO**, 4 GB or more.
2. Start the VM and run:

   ```sh
   lepton-install
   ```

   Confirm the disk, then create your account: a user name and a
   password. (A disk with other systems on it keeps them: Lepton offers
   an empty partition or free space instead.)
3. `poweroff`, eject the ISO (**CD/DVD → Clear**) and start the VM again.
4. Log in with your user name and password.

The disk now has two partitions: `LEPTON-OS`, which is Lepton itself, and
`LEPTON-DATA`, which holds your home, your apps and your settings. A new
release replaces only the first (lesson 18).

More: [Install to a disk](getting-started.html#install-to-a-disk).

## 3. The shell

You're in `lsh`, Lepton's shell. It works like zsh or bash, with line
editing, history, completion and a starship prompt.

```sh
echo "Hello from $USER"
for i in 1 2 3; do echo "round $i"; done
ls -la | grep conf          # pipes
sleep 30 &                  # a background job
jobs
history | tail
```

Press **Tab** to complete commands and file names, **↑** for history,
and **C-r** to search it. Your aliases come from your `~/.zshrc`.

More: [The shell](shell.html).

## 4. Files and the editor

```sh
mkdir -p ~/notes && cd ~/notes
echo "first line" > todo.txt
cat todo.txt
le todo.txt                 # the editor
```

`le` is a Spacemacs-style editor: you start in normal mode. Press `o` to
open a line below, type something, press **Esc**, then `:wq` to save and
quit (or **SPC f s** to save). `vi`, `vim` and `emacs` start it too.

```sh
grep -n line todo.txt
wc -l todo.txt
cp todo.txt done.txt && ls
```

More: [The editor](editor.html), [System](system.html).

## 5. tmux

`tmux` splits your screen into windows and panes, with your
`~/.tmux.conf`. The prefix is **C-t**.

```sh
tmux
```

Then try **C-t c** (a new window: it asks for a name), **C-t n** (the
next one), **C-t v** and **C-t s** (split the pane side by side, or top
and bottom), and **C-t d** to detach. `tmux attach` brings it back.

More: [tmux](tmux.html).

## 6. The network and Wi-Fi

The VM's network works by itself.

```sh
ip addr
ping -c 3 example.com
curl -s https://example.com | head
www example.com             # a text web browser
```

With a USB Wi-Fi adapter passed to the VM (UTM's **USB** menu):

```sh
wifi scan
sudo wifi connect MyNetwork     # asks for the passphrase
wifi
```

More: [Networking](networking.html).

## 7. git, GitHub and SSH

```sh
ssh-keygen                      # your key, ~/.ssh/id_ed25519
gh auth login                   # a GitHub token
gh ssh-key add                  # upload your key
git clone git@github.com:you/your-repo.git
cd your-repo
echo "hi" >> README.md
git add README.md && git commit -m "Hello from Lepton" && git push
```

`ssh you@server` logs in to your own machines with the same key.

More: [git and GitHub](git.html), [SSH](ssh.html).

## 8. Elixir and packages

Lepton's commands are written in Elixir, and you can write your own.

```sh
iex                                           # Elixir, interactive (C-d or exit to leave)
elixir -e 'IO.puts Enum.sum(1..100)'
lpm search json
sudo lpm install jason
elixir -e 'IO.puts Jason.encode!(%{hello: "lepton"})'
```

More: [Packages](packages.html).

## 9. Services

`svc` keeps programs running in the background and starts them at boot.

```sh
sudo svc new clock 'while true; do date; sleep 60; done'
sudo svc enable --now clock
svc
svc logs clock -f               # C-c to stop following
sudo svc stop clock
```

More: [Services](services.html).

## 10. Users and sudo

Your account runs administrative commands with `sudo`, which asks for
your password.

```sh
whoami
id
sudo useradd --sudo -c "Sam Smith" sam     # another account, which may use sudo
sudo passwd sam
```

More: [Users and sudo](users.html).

## 11. The desktop

Lepton has a graphical desktop, Photon, with two looks. From the VM's
window (not an SSH session):

```sh
classic                         # Windows 95-style, with a Start menu
```

- Double-click **Terminal** on the desktop, or press **Alt+Return**.
- Drag windows by their title bars; **Alt+Tab** switches between them.
- **Start** (or **C-Esc**) has the apps; **Exit Desktop** goes back to
  the console (so does **C-Alt-Backspace**).
- The taskbar's tray has the volume, and Wi-Fi and Bluetooth when there's
  hardware for them, next to the clock.

`photon` starts Photon's own, plainer look. In a terminal window,
`photon info` lists the windows and `photon screenshot shot.png` saves
the screen.

More: [The desktop](desktop.html).

## 12. Firefox

Firefox runs on the desktop. The first time, it is downloaded and
installed (about 137 MB):

- double-click **Firefox** on the classic desktop, or
- run `firefox https://trylepton.app` in a terminal window.

Give the VM 4 GB of memory for it. It plays video and sound too.

More: [Firefox and other apps](apps.html).

## 13. More displays

Give the VM a second display (UTM: add a **Display**), then, on the
desktop:

```sh
photon display              # the displays
photon display mirror       # the same picture on both
photon display extend       # one desktop across both (the default)
```

**Alt+Shift+Right** moves a window to the next display.

More: [USB, hubs and displays](usb.html#displays).

## 14. USB devices, drives and SD cards

Plug devices into the Mac and pass them to the VM from UTM's **USB**
menu. Hubs, keyboards and mice work as soon as they appear.

```sh
usb                         # the USB devices, as a tree of hubs and ports
input                       # keyboards, mice, tablets
```

A USB stick or SD card is mounted under `/media` within a second or two,
and gets an icon on the classic desktop:

```sh
lsblk
ls /media
cp ~/notes/todo.txt /media/MYSTICK/
eject /media/MYSTICK        # then unplug it
```

More: [USB, hubs and displays](usb.html), [USB drives and SD cards](storage.html).

## 15. Sound

Give the VM a sound device (UTM: **Sound**), then:

```sh
sound test                  # three notes
volume                      # Volume: 50% on HDA Intel
volume 70
volume mute
volume unmute
beep 440 500
```

On the desktop, the volume keys work, and the classic desktop's speaker
opens a volume control.

More: [Sound](sound.html).

## 16. Bluetooth

With a USB Bluetooth adapter passed to the VM, put a keyboard, mouse or
pair of headphones in pairing mode, then:

```sh
bluetooth scan
sudo bluetooth pair "MX Keys"   # by name or address
bluetooth
```

The first time, this installs Bluetooth support (about 8 MB). Pairing
a keyboard shows a number: type it on the Bluetooth keyboard and press
Enter. Paired headphones become where sound plays.

On the classic desktop, click the Bluetooth rune in the tray for the same
things.

More: [Bluetooth](bluetooth.html).

## 17. Your dotfiles

Lepton reads real configuration files: your `~/.zshrc`, `~/.spacemacs`,
`~/.tmux.conf`, starship prompt and `~/.gitconfig`.

```sh
keys                        # every key binding that was loaded
keys tmux
```

More: [Your dotfiles, applied](dotfiles.html).

## 18. Upgrade to a new release

When a new release comes out:

1. Download the new ISO and choose it for the VM's **CD/DVD** drive.
2. Start the VM, log in, and run `sudo lepton-install`. It finds your
   Lepton and upgrades it.
3. `sudo poweroff`, eject the ISO and start the VM.

Only `LEPTON-OS` is replaced: your files, apps, accounts and settings
stay. You can also upgrade from inside Lepton with a downloaded ISO:
`sudo lepton-install --iso lepton.iso`, then `sudo reboot`.

More: [Updating Lepton](updating.html).

## Where next

- [Commands](commands.html): every command and its options.
- [Key bindings](keybindings.html): the editor's, tmux's and the shell's.
- [Limitations](limitations.html): what Lepton doesn't do yet.
- `sudo poweroff` when you're done.
