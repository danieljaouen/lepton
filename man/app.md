## DESCRIPTION

Install, update and remove native Linux apps, built from Alpine Linux's
packages: `firefox`, `typst`, `ffmpeg` (for `play` and `radio`), `snes` (for `snes`),
`imagemagick` (for `magick`), `compressors` (xz and zstd, for `tar`),
`bluetooth`, `postgresql`, `qemu` and others (`app` lists them). Apps live on the data partition of
an installed system. Listing is for everyone; the other commands take
`sudo`.

## COMMANDS

- `app`, `app list`: the apps, with whether and which version is
  installed.
- `install NAME`: download and install an app.
- `update [NAME]`: update an app (all installed apps with no NAME) to
  the latest packages.
- `update-all`: update every installed app, one after another, then say
  which were updated (from which version to which), which were up to
  date and which failed.
- `reinstall NAME`: download and set up all of an app's packages again,
  for an app that is broken or won't start. Close the app first. Your
  settings (Firefox's profile, in your home) are kept.
- `remove NAME`: remove an app.

## EXAMPLES

    app
    sudo app install firefox
    sudo app update
    sudo app update-all
    sudo app reinstall firefox

## SEE ALSO

firefox(1), typst(1), play(1), snes(1), magick(1), bluetooth(1), lpm(1), https://trylepton.app/docs/apps.html
