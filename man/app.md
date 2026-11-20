## DESCRIPTION

Install, update and remove native Linux apps, built from Alpine Linux's
packages: `firefox` and `bluetooth`. Apps live on the data partition of
an installed system. Listing is for everyone; the other commands take
`sudo`.

## COMMANDS

- `app`, `app list`: the apps, with whether and which version is
  installed.
- `install NAME`: download and install an app.
- `update [NAME]`: update an app (all installed apps with no NAME) to
  the latest packages.
- `remove NAME`: remove an app.

## EXAMPLES

    app
    sudo app install firefox
    sudo app update

## SEE ALSO

firefox(1), bluetooth(1), lpm(1), https://trylepton.app/docs/apps.html
