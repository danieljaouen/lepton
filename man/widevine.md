## DESCRIPTION

Install Widevine, the DRM plugin (a "content decryption module") that
Firefox needs to play protected music and video: Spotify's web player,
Netflix, Disney+, Amazon Prime Video and other streaming sites. Without
it those sites say the browser isn't supported, or their player never
starts.

Firefox downloads Widevine by itself on x86-64 Linux, but Mozilla has
no build of it for ARM64 Linux, which is what Lepton runs on. Google's
Chrome for ARM64 Linux has one, so `widevine install` downloads Chrome's
package from Google's own repository (dl.google.com, about 140 MB,
checked against the SHA-256 the repository lists), takes the plugin out
of it, and deletes the rest. Widevine is Google's software, not open
source, under Google's terms (kept with it as LICENSE): Lepton can't
include it, so it comes from Google, onto your machine, when you ask.

The plugin is built for glibc, not for musl, the C library Lepton's
native apps use. It loads through gcompat (glibc's names over musl,
which comes with Firefox), and four of its relocations, which musl's
loader doesn't do (GNU indirect functions, which pick memory-tagging
versions of a few functions on CPUs that have it), are resolved when it
is installed: each picks the plain version.

Restart Firefox after installing it. Then, on a site that needs it,
Firefox plays without asking (DRM is turned on in Lepton's Firefox).

## COMMANDS

- `widevine` or `widevine status`: whether it is installed, and which
  version.
- `widevine install`: download and install it (root: `sudo`). Install
  Firefox first: its xz unpacks Chrome's package.
- `widevine update`: install the Widevine of a newer Chrome, if there
  is one (root).
- `widevine remove`: remove it (root).

## FILES

- `/var/lib/lepton/widevine/gmp-widevinecdm/system-installed`: the
  plugin and its manifest (Firefox's `MOZ_GMP_PATH`).
- `/var/lib/lepton/widevine/LICENSE`: Google's terms.

## EXAMPLES

    sudo widevine install
    widevine

## SEE ALSO

firefox(1), app(1), https://trylepton.app/docs/apps.html
