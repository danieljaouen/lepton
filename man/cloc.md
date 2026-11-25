## DESCRIPTION

Count lines of code: for each language, the files, blank lines, comment
lines and code lines under each PATH (folders are walked; `.git` and
other version-control folders are skipped). It counts as cloc 2.08
(github.com/AlDanial/cloc) does, so its numbers are cloc's: a line with
code and a trailing comment is code; Elixir's `@moduledoc` and `@doc`
heredocs are comments (`@typedoc` isn't), and so is anything between
`/*` and `*/`, as cloc's filters have it. Scripts without an extension
are known by their `#!` line. Identical files count once; files in no
language it knows, and binary files, are ignored.

## OPTIONS

- `--vcs=git`: count what git tracks (not what it ignores, nor
  submodules), as `git ls-files` lists it.
- `--by-file`: a line for each file rather than each language.
- `--include-lang=L1,L2`, `--exclude-lang=L1,L2`: only these languages,
  or not these (names as the table shows them; `--show-lang` lists them).
- `--exclude-dir=D1,D2`: skip folders of these names (`_build,deps`).
- `--exclude-ext=E1,E2`: skip files with these extensions.
- `--match-f=REGEX`, `--not-match-f=REGEX`: only the files whose names
  match, or don't.
- `--json`, `--csv`, `--md`: the report as JSON, CSV or a Markdown table.
- `--quiet` (`-q`): the table alone; `--hide-rate`: no timing.

## EXAMPLES

    cloc .
    cloc --vcs=git .
    cloc --include-lang=Elixir --exclude-dir=lepton_build,mix lib
    cloc --by-file --include-lang=Elixir lib | head
    cloc --json lib > counts.json

## SEE ALSO

wc(1), du(1), git(1)
