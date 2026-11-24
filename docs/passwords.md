---
title: Passwords
order: 18
section: desktop
summary: A password manager like 1Password, on the desktop and in the shell. It keeps logins, secure notes and cards in an encrypted vault, and has one-time codes, a password generator and an audit.
---

# Passwords

Lepton has a password manager. It keeps your logins, secure notes and
cards in a vault: a file encrypted with a master password that only you
know. Use it from the classic desktop's **Passwords** window or from the
shell with `vault`. Both work on the same vault, and unlocking it in one
unlocks it in the other.

## Make your vault

On the [classic desktop](desktop.html#the-classic-desktop), double-click
the **Passwords** icon (the padlock), or choose **Start → Passwords**.
The first time, it asks for a master password, twice. In the shell:

```sh
vault init
```

The master password must be at least 8 characters, and nothing can
recover it: if you forget it, the vault can't be opened. A few unrelated
words make a strong password that you can remember.

## The Passwords window

- On the left are your items, favourites first, with a search field
  above them. Type to search titles, user names, websites, tags and
  notes, and press Escape to clear the search. Up and Down choose an
  item.
- On the right is the item you chose. Passwords and card codes show as
  stars until you click **Show**. **Copy** puts a field on the
  clipboard, and Return copies the password. If a login has one-time
  passwords, you see the current code and the seconds it has left. A
  coloured line under the password shows its strength: red is weak,
  yellow is fair and green is good.
- **New** (Ctrl+N) adds a login, a secure note or a card. A new login
  comes with a generated password, and the **New** button next to the
  password field makes another one. **Edit** (Ctrl+E) changes the item,
  and keeps the old password in its history. Tab moves between fields,
  and Return or Ctrl+S saves. In the notes field, Return starts a new
  line.
- **Delete** removes the item after you confirm.
- **Generator** makes a password for you to copy. You choose its length
  and whether it has symbols.
- **Lock** (Ctrl+L) locks the vault.

Ctrl+F goes to the search field, Ctrl+C copies the password, and Ctrl+V
pastes into a field.

## In the shell

```sh
vault add GitHub username=dan url=https://github.com   # with a generated password
vault add -p Bank username=me                           # type the password instead
vault add -k note "Alarm code" notes="1234, then ring twice"
vault add -k card Visa cardholder="Dan" number=4111111111111111 expiry=12/29 code=123
vault list                      # or: vault list git, vault list -t work
vault show github               # secrets hidden; -r shows them
vault copy github               # the password, to the clipboard
vault copy github username
vault get github                # print it, for scripts: $(vault get github)
vault otp github                # the current one-time code
vault edit github url=https://github.com/login tags=work,code
vault edit -g github            # a new generated password
vault rm github
vault generate -n 32            # a password, not saved anywhere
```

To name an item, give its title, the start of its ID (from `vault
list`), or any part of its title that matches only that item.

Set fields with `FIELD=VALUE`. `FIELD=` removes a field. Any name that
isn't one of the kind's own fields makes a new field, such as
`pin=1234`. `tags=` takes a list separated by commas, and
`favorite=true` puts an item at the top of the list.

Everything you type after `=` stays in your shell's history. To type a
password, use `-p` instead of `password=`.

## Locking

The vault locks itself 10 minutes after you last used it. Restarting
Lepton also locks it.

- `vault unlock -t 60` waits for an hour without use before it locks.
- `vault unlock -t 0` keeps it unlocked until you lock it yourself.
- `vault lock`, or **Lock** in the window, locks it at once.

When the vault is locked, `vault` asks for the master password first.

The vault's key is kept only in memory, and only while the vault is
unlocked. Each user has their own vault, and unlocking yours doesn't
unlock anyone else's.

## The clipboard

When you copy a password, card code or one-time code, Lepton takes it off
the clipboard after 45 seconds, unless you have copied something else
since. In UTM the clipboard is shared with your Mac, so you can copy a
password in Lepton and paste it on the Mac (see [Sharing it with your
Mac](system.html#sharing-it-with-your-mac-utm)).

## One-time passwords

To add a site's two-factor codes to a login, give its setup key as
`otp`. The setup key is the text shown under the QR code; an
`otpauth://` link works too:

```sh
vault edit github otp=JBSWY3DPEHPK3PXP
vault otp github
```

These are TOTP codes (RFC 6238), the same codes that authenticator apps
show.

## Checking your passwords

`vault audit` lists weak passwords, and passwords used by more than one
item, like 1Password's Watchtower. To give an item a strong new
password, run `vault edit -g ITEM`, then change the password on the
website too.

## Moving from another password manager

Export your passwords as CSV from 1Password, Bitwarden, Chrome, Firefox,
Safari or LastPass, then import them and delete the export:

```sh
vault import passwords.csv
rm passwords.csv          # it isn't encrypted
```

`vault import` finds the columns by their names: title or name, url,
username, password, otp or totp, notes, and tags.

To export, `vault export` writes your items as JSON and `vault export
--csv` writes them as CSV. Use this for a backup or to move to another
password manager. Exports aren't encrypted, so keep them safe.

## The vault file

The vault is `~/.vault/vault`, or whatever file `$VAULT_FILE` names.
Only you can read it. Before each change, Lepton keeps the previous
version as `~/.vault/vault.old`.

To back up the vault, copy the file anywhere: a copy is as safe as your
master password. On an installed Lepton, it is kept with your home
directory.

How it is encrypted:

- A random 256-bit key encrypts your items with AES-256-GCM.
- That key is itself encrypted with a key made from your master
  password by **Argon2id** (64 MiB of memory, 3 passes, a random salt),
  the memory-hard password hash of RFC 9106. Each guess at your master
  password costs an attacker 64 MiB as well as time, which makes
  guessing on graphics cards and custom chips slow and expensive. It
  takes a few seconds when you unlock (longer where UTM emulates the CPU,
  as on an iPad); the vault stays unlocked until it locks again.

Vaults made before Lepton 1.25 use PBKDF2-HMAC-SHA256 (600,000
iterations). They still open; `vault status` says which a vault uses,
and `vault upgrade` (or changing the master password with `vault
passwd`) moves it to Argon2id, keeping your items as they are.

Only symmetric cryptography is involved (AES-256, SHA-256, BLAKE2b),
which quantum computers don't break: the best known quantum attack only
halves a key's strength, leaving AES-256 with 128 bits. Your master
password matters more: make it a long passphrase.

With a wrong password, or if the file has been changed in any way, the
vault doesn't decrypt. `vault passwd` changes the master password.

<!-- commands: vault -->
