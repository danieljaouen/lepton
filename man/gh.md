## DESCRIPTION

Work with GitHub from the command line, compatible with GitHub's own
`gh`. Commands that act on "this repository" use the GitHub remote of
the git repository you are in.

## COMMANDS

- `auth login [--with-token]`: store a personal access token (pasted, or
  read from standard input) in `~/.config/gh/hosts.yml`. Give it the
  scopes `repo` and `read:org`, and `admin:public_key` for `ssh-key`.
  git uses it for HTTPS pushes.
- `auth status`, `auth token`, `auth logout`: show, print or remove the
  stored login.
- `repo view [OWNER/REPO]`: a repository's description, counts and
  README.
- `repo list [OWNER]`: your (or OWNER's) repositories, recently updated
  first.
- `repo clone OWNER/REPO [DIR]`: clone a repository (`REPO` alone means
  one of yours), over SSH if `git_protocol` is `ssh`.
- `repo create NAME [--private]`: create a repository on your account.
- `ssh-key list`: the SSH keys on your account.
- `ssh-key add [FILE] [-t TITLE]`: upload a public key
  (`~/.ssh/id_ed25519.pub` by default).
- `config get git_protocol`, `config set git_protocol https|ssh`: how
  `repo clone` clones.
- `issue list`, `issue view N`, `issue create -t TITLE [-b BODY]`:
  issues.
- `pr list`, `pr view N`: pull requests.
- `browse`: print this repository's GitHub URL.
- `api PATH [-X METHOD] [-f KEY=VALUE...]`: call the REST API and print
  the JSON (`{owner}/{repo}` in PATH means this repository).

## ENVIRONMENT

- `GH_TOKEN`: a token to use instead of the stored one.

## EXAMPLES

    gh auth login
    gh ssh-key add
    gh repo clone you/app
    gh api /user

## SEE ALSO

git(1), ssh-keygen(1)
