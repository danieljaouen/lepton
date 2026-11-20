## DESCRIPTION

Lepton's git, written in Elixir. It reads and writes the same repository
format as upstream git: loose and packed objects, index v2, refs,
packed-refs and `.gitignore`. It talks to GitHub and other servers over
HTTPS and SSH.

Your `~/.gitconfig` is honoured: its aliases (including `!` shell
aliases), `user.name` and `user.email`, `[include]`, `core.excludesfile`,
`http.sslVerify` and `url.BASE.insteadOf` and `pushInsteadOf`.

## GLOBAL OPTIONS

- `-C DIR`: run as if started in DIR.
- `--no-pager`: accepted (git never pages).

## COMMANDS

- `init [-b BRANCH] [-q] [DIR]`: create a repository (branch `main` by
  default).
- `clone URL [DIR]`: copy a repository. URL may be HTTPS,
  `git@host:owner/repo.git`, `ssh://...` or an `~/.ssh/config` alias.
- `status [-s] [-b]`: show what is staged, changed and untracked (`-s`
  short format).
- `add [-A] [PATH...]`: stage changes (all of them with `-A` or no
  PATH).
- `rm [--cached] PATH...`: remove files from the index (and from the
  working tree unless `--cached`).
- `restore [--staged | -S] PATH...`: discard changes to PATHs, or
  unstage them.
- `reset [--soft | --mixed | --hard] [COMMIT]`: move the branch to
  COMMIT (HEAD by default); `--mixed` (the default) also resets the
  index, `--hard` the working tree too. `reset PATH` unstages PATH.
- `commit [-a] [-m MESSAGE | -F FILE] [--amend] [--allow-empty]`: record
  the staged changes. Without `-m` or `-F`, the editor opens for the
  message.
- `log [-n N] [-p] [--oneline] [--graph] [--all] [--pretty=FORMAT]
  [REV]`: show the history; `--pretty=format:...` takes `%h`, `%H`,
  `%s`, `%an`, `%ar` and the like.
- `show [REV]`: show a commit and its diff.
- `diff [--cached | --staged] [PATH...]`: show unstaged (or staged)
  changes.
- `branch [-a | -r] [-v]`: list branches; `branch NAME [START]` creates
  one; `branch -d NAME` deletes one.
- `checkout BRANCH`, `switch BRANCH`: switch branches; `-b NAME` (or
  `switch -c NAME`) creates it first. `checkout -- PATH` discards
  changes to PATH.
- `merge REV`: merge by fast-forward.
- `stash`, `stash pop`: put changes aside and bring them back.
- `tag [NAME [REV]]`: list tags or create a lightweight tag.
- `fetch [REMOTE]`, `pull [REMOTE [BRANCH]]`: get new commits (pull
  fast-forwards the current branch).
- `push [-u] [-f] [REMOTE [BRANCH]]`: send commits; `-u` sets the
  upstream, `-f` forces.
- `remote -v`, `remote add NAME URL`, `remote set-url NAME URL`: manage
  remotes.
- `config [--global] KEY [VALUE]`, `config -l`: read or set
  configuration.
- `ls-remote URL`, `ls-files [-o]`, `rev-parse REV`, `cat-file -t|-s|-p
  OBJECT`, `hash-object [-w] FILE`: plumbing.
- `version`: print the version.

## AUTHENTICATION

Over HTTPS, git uses the token stored by `gh auth login` (or `GH_TOKEN`).
Over SSH it uses your keys in `~/.ssh` (see `ssh`).

## BUGS

Merges are fast-forward only (no three-way merge), and there is no
rebase.

## EXAMPLES

    git clone git@github.com:you/app.git
    git add -A && git commit -m "Fix the thing" && git push
    git log --oneline -n 10

## SEE ALSO

gh(1), ssh(1), ssh-keygen(1), le(1), diff(1)
