## DESCRIPTION

Start the Firefox web browser on the desktop, opening each URL. Run it
from a terminal window in `photon` or `classic`, or from the classic
desktop's icon or Start menu. The first time, Firefox is installed
(which takes `sudo` unless you are root); when updates are due, they
are installed before it starts.

Firefox is not tied to the terminal it was started from: it keeps
running when that window is closed.

## FILES

- `~/.cache/lepton/firefox.log`: Firefox's output.
- `~/.mozilla`: your Firefox profile.

## EXAMPLES

    firefox
    firefox https://trylepton.app/

## SEE ALSO

app(1), photon(1), classic(1), www(1), https://trylepton.app/docs/apps.html
