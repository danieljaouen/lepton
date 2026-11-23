## DESCRIPTION

Start the Firefox web browser on the desktop, opening each URL. Run it
from a terminal window in `photon` or `classic`, or from the classic
desktop's icon or Start menu. The first time, Firefox is installed
(which takes `sudo` unless you are root); when updates are due, they
are installed before it starts.

Its fonts cover Chinese, Japanese and Korean (Noto CJK), and Thai,
Hindi, Bengali, Tamil, Khmer, Lao, Myanmar, Arabic and Hebrew, besides
Latin, Greek and Cyrillic. An install from before these fonts came with
Firefox downloads them on its next start and uses them from the start
after that; `sudo app update firefox`, with Firefox closed, does it at
once.

Firefox is not tied to the terminal it was started from: it keeps
running when that window is closed.

Firefox opens the windows and tabs you had open last time, whether you
quit it or powered off or rebooted with it open (it saves them every 5
seconds). Settings > General > "Open previous windows and tabs" turns
this off.

When Firefox is already running, `firefox URL` opens URL in a new tab
of it (and so does `open`). The running Firefox receives it over a
D-Bus session bus that Lepton starts with Firefox and stops when it
closes. If a Firefox started without that bus (installed before it came
with Firefox) is still open, `firefox` says to close it and start it
again.

Spotify's web player, Netflix and other streaming sites need Widevine,
a DRM plugin from Google: install it with `sudo widevine install`, and
restart Firefox. See widevine(1).

## FILES

- `~/.cache/lepton/firefox.log`: Firefox's output.
- `~/.mozilla`: your Firefox profile.
- `$XDG_RUNTIME_DIR/bus`: Firefox's session bus, while it runs.

## EXAMPLES

    firefox
    firefox https://trylepton.app/

## SEE ALSO

app(1), widevine(1), photon(1), classic(1), www(1), https://trylepton.app/docs/apps.html
