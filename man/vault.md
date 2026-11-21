## DESCRIPTION

A password manager. It keeps logins, secure notes and cards in a vault,
encrypted with a master password: AES-256-GCM, with the key made by
PBKDF2-HMAC-SHA256 (600,000 iterations). The classic desktop's
**Passwords** window works on the same vault, and unlocking it in one
unlocks it in the other.

When the vault is locked, `vault` asks for the master password first. It
reads it from the terminal, or, with no terminal, as the first line of
standard input. The vault locks itself after 10 minutes without use.

To name an ITEM, give its title, the start of its ID (from `vault
list`), or any part of its title that matches only that item.

FIELD=VALUE sets a field, and `FIELD=` removes it. Each kind has its own
fields:

- a login: `username`, `password`, `url`, `otp` (a TOTP secret or an
  `otpauth://` link) and `notes`;
- a card: `cardholder`, `number`, `expiry`, `code` and `notes`;
- a note: `notes`.

Any other name makes a new field. `tags=` takes a list separated by
commas, and `favorite=true` lists an item first.

## COMMANDS

- `status` (or nothing): where the vault is, and whether it is unlocked.
- `init`: make a vault, choosing the master password.
- `unlock [-t MIN]`: unlock the vault until it goes MIN minutes without
  use (default 10). With 0, it stays unlocked until `vault lock`.
- `lock`: lock it now.
- `list [-t TAG] [QUERY]` (also `ls`): the items, or only those that
  match QUERY or are tagged TAG.
- `show [-r] ITEM`: an item's fields, with secrets as stars unless you
  give `-r`.
- `get ITEM [FIELD]`: print a field (by default, the password). `get
  ITEM otp` prints the current one-time code.
- `copy ITEM [FIELD]`: put a field on the clipboard. It is taken off
  again after 45 seconds.
- `otp ITEM`: print the current one-time code.
- `add [-k KIND] [-g] [-n LEN] [-p] [-S] TITLE [FIELD=VALUE...]`: add an
  item. KIND is `login` (the default), `note` or `card`. A login gets a
  generated password unless you give `-p` or `password=`.
- `edit [-g] [-n LEN] [-p] [-S] ITEM FIELD=VALUE...`: change an item.
  The old password is kept in the item's history.
- `rm ITEM` (also `delete`): delete an item.
- `generate [-n LEN] [-S] [-c]` (also `gen`): print a random password,
  or copy it with `-c`.
- `audit`: list weak and reused passwords. Exits 1 if it finds any.
- `passwd`: change the master password.
- `import FILE`: add the items from a CSV export (1Password, Bitwarden,
  Chrome, Firefox, Safari or LastPass) or from `vault export` (JSON).
  With `-` as FILE, it reads standard input.
- `export [--csv]`: write every item to standard output, as JSON or CSV.
  The export isn't encrypted.
- `gui`: open the Passwords window (on the desktop).

## OPTIONS

- `-g`: give the item a generated password.
- `-n LEN`: the generated password's length (default 20).
- `-S`: leave symbols out of the generated password.
- `-p`: ask for the password.
- `-k KIND`: the kind of a new item.
- `-r`: show secrets.
- `-t TAG` (with `list`): only items with this tag.
- `-t MIN` (with `unlock`): the minutes without use before it locks.

## EXAMPLES

    vault init
    vault add GitHub username=dan url=https://github.com
    vault copy github
    vault edit github otp=JBSWY3DPEHPK3PXP
    vault otp github
    git clone https://dan:$(vault get github)@example.com/repo.git
    vault import ~/Downloads/1password.csv
    vault audit

## ENVIRONMENT

- `VAULT_FILE`: use this vault file instead of `~/.vault/vault`.

## FILES

- `~/.vault/vault`: the vault (only you can read it).
- `~/.vault/vault.old`: the version from before the last change.

## SEE ALSO

pbcopy(1), https://trylepton.app/docs/passwords.html
