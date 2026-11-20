---
title: Printing
order: 17
summary: Print to network printers (AirPrint, IPP Everywhere) from the shell and from Firefox, with CUPS's commands.
---

# Printing

Lepton prints to **network printers** that speak IPP, the driverless
way: AirPrint and IPP Everywhere printers, which is most printers made in
the last ten years. Printers on your network are found by themselves;
there is nothing to install.

```sh
printers                     # the printers, and choose your default
lp notes.txt                 # print (to your default printer)
lp -d office -n 2 report.pdf # to a given printer, two copies
lpstat -p -o                 # printers, and the jobs waiting
cancel office-3              # cancel a job
```

On the [classic desktop](desktop.html#the-classic-desktop), **Start →
Printers** lists them and lets you choose your default. Firefox's
**Print** dialog lists the same printers, and prints to the one you
choose.

## What can be printed

PDF files, JPEG pictures and plain text (which Lepton lays out as a PDF,
in Courier, on the printer's paper size: A4 or US Letter). The printer
must take PDF (or JPEG, for pictures): most do. Firefox prints web pages
as PDF.

## Printers

Printers found on the network (by mDNS, as AirPrint finds them) appear
by themselves, named after the printer (`Office_Laser`), and can be used
without adding them. `lpinfo -v` lists what is found right now.

A printer that can't be found that way (on another network, say) is
added by its address, with sudo:

```sh
sudo lpadmin -p office -v ipp://192.168.1.50/ipp/print -D "Office laser" -L "2nd floor"
sudo lpadmin -d office      # the system's default
sudo lpadmin -x office      # remove it
```

The address is usually `ipp://ADDRESS/ipp/print` (`ipps://` for an
encrypted connection); the printer's web page or manual has it.

Your default printer is yours: `printers` or `lpoptions -d NAME` keeps it
in `~/.cups/lpoptions`, where Firefox (CUPS's library) reads it too.
Without one, the system's default is used, or the only printer there is.

## The print service

`cupsd`, run by the `cups` service (on by default), keeps the queue and
sends each job on to its printer. Like CUPS, it speaks IPP on
`127.0.0.1:631`, only to this machine, which is how `lp` and Firefox
reach it. <http://localhost:631/> shows the printers and jobs (in
Firefox), and `svc logs cups` what was printed or why not.

## Not supported

USB printers, printers that take only raster images (`image/pwg-raster`,
`image/urf`, no PDF), PostScript and PCL drivers, and sharing Lepton's
printers with other computers.

<!-- commands: printers lp lpr lpstat cancel lpadmin lpoptions lpinfo cupsd -->
