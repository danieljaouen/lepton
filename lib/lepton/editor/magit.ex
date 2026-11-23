defmodule Lepton.Editor.Magit do
  @moduledoc """
  A magit-style git porcelain inside `le` (`SPC g s`).

  Modified buffers visiting the repository's files are saved first, as
  `magit-save-repository-buffers` does, so git sees what you typed.

  Evilified keys: `s`/`u` stage/unstage the file at point (on a section's
  heading: every file in it), `S`/`U` all,
  `TAB` toggles the file's diff, `c c` commits (write the message, then
  `:wq` / `SPC f s` + `q`), `c a` amends, `P p` pushes and `F p` pulls
  (GitHub over HTTPS), `b b`/`b c` switch/create branches, `l l` log,
  `g r` refresh, `q` quits. The user's magit-mode-map bindings
  (`C-j`/`C-k` window movement, `/`, `n`, `N`, `Z` stash, `zt`, `zz`)
  are applied on top.
  """

  alias Lepton.{Editor, Git}
  alias Lepton.Editor.Buffer

  def status(st) do
    dir = Editor.api(st, :dir, nil)

    case Git.root(dir) do
      nil -> Editor.api(st, :error, "Not inside a Git repository")
      root ->
        {st, saved} = Editor.api(st, :save_repo_buffers, root)
        st = render_status(st, root, MapSet.new())
        if saved != [], do: Editor.api(st, :msg, "Saved #{Enum.join(saved, ", ")}"), else: st
    end
  end

  defp render_status(st, root, expanded) do
    repo = Git.Repo.open(root)
    s = Git.status(repo)
    head = Git.head_summary(repo)

    file_lines = fn title, entries, kind ->
      if entries == [] do
        []
      else
        ["#{title} (#{length(entries)})"] ++
          Enum.flat_map(entries, fn {path, how} ->
            line = "#{String.pad_trailing(to_string(how), 10)} #{path}"
            diff = if MapSet.member?(expanded, {kind, path}), do: Git.file_diff(repo, path, kind) |> String.split("\n", trim: true), else: []
            [line | diff]
          end) ++ [""]
      end
    end

    untracked = for p <- s.untracked, do: {p, :untracked}

    lines =
      ["Head:     #{head}", "Remote:   #{Git.remote_url(repo, "origin") || "(none)"}", ""] ++
        file_lines.("Untracked files", untracked, :untracked) ++
        file_lines.("Unstaged changes", s.unstaged, :unstaged) ++
        file_lines.("Staged changes", s.staged, :staged) ++
        ["Recent commits"] ++ Enum.map(Git.log(repo, 10), fn c -> "#{String.slice(c.sha, 0, 7)} #{c.subject}" end)

    Editor.special_buffer(st, "magit: #{Path.basename(root)}", :magit, Enum.join(lines, "\n"), %{root: root, expanded: expanded})
  end

  def log(st) do
    case Git.root(Editor.api(st, :dir, nil)) do
      nil -> Editor.api(st, :error, "Not inside a Git repository")
      root ->
        repo = Git.Repo.open(root)
        lines = for c <- Git.log(repo, 200), do: "#{String.slice(c.sha, 0, 7)} #{String.pad_trailing(c.author_name, 16)} #{c.subject}"
        Editor.special_buffer(st, "magit-log: #{Path.basename(root)}", :log, Enum.join(lines, "\n"), %{root: root})
    end
  end

  def diff(st) do
    case Git.root(Editor.api(st, :dir, nil)) do
      nil -> Editor.api(st, :error, "Not inside a Git repository")
      root ->
        text = Git.diff_text(Git.Repo.open(root), :unstaged)
        Editor.special_buffer(st, "magit-diff: #{Path.basename(root)}", :log, if(text == "", do: "(no unstaged changes)", else: text), %{root: root})
    end
  end

  # Which file (and section) is at point? On a section's heading: the
  # section, and no file.
  defp at_point(st) do
    b = Editor.buf(st)
    {l, _} = Editor.api(st, :cursor, nil)
    lines = Buffer.lines(b)

    section =
      lines
      |> Enum.take(l + 1)
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        cond do
          String.starts_with?(line, "Untracked files") -> :untracked
          String.starts_with?(line, "Unstaged changes") -> :unstaged
          String.starts_with?(line, "Staged changes") -> :staged
          String.starts_with?(line, "Recent commits") -> :commits
          true -> nil
        end
      end)

    # Diff lines belong to the file line above them (within the section).
    file_line =
      lines
      |> Enum.take(l + 1)
      |> Enum.reverse()
      |> Enum.take_while(&(not Regex.match?(~r/^(Untracked files|Unstaged changes|Staged changes|Recent commits) \(?/, &1)))
      |> Enum.find(&Regex.match?(~r/^(untracked|modified|new file|deleted|added|renamed|typechange)\s/, &1))

    path = file_line && file_line |> String.split(~r/\s+/, parts: 2) |> List.last() |> String.trim()
    {section, path}
  end

  def action(st, action) do
    b = Editor.buf(st)
    root = b.meta[:root]
    repo = root && Git.Repo.open(root)
    {section, path} = at_point(st)

    result =
      case action do
        _ when repo == nil -> Editor.api(st, :error, "Not in a magit buffer")
        :magit_stage when section in [:untracked, :unstaged] -> git(st, fn -> Git.add(repo, paths(repo, section, path)) end)
        :magit_stage -> Editor.api(st, :error, "Nothing to stage here (s on a file under Untracked files or Unstaged changes)")
        :magit_unstage when section == :staged -> git(st, fn -> Git.unstage(repo, paths(repo, section, path)) end)
        :magit_unstage -> Editor.api(st, :error, "Nothing to unstage here (u on a file under Staged changes)")
        :magit_stage_all -> git(st, fn -> Git.add(repo, ["."]) end)
        :magit_unstage_all -> git(st, fn -> Git.unstage(repo, :all) end)
        :special_refresh -> refresh(st)
        :special_toggle when path != nil -> toggle(st, section, path)
        :special_open when path != nil -> Editor.api(st, :visit, Path.join(root, path))
        :special_open when b.kind == :list -> Editor.api(st, :grep_result, nil)
        :magit_commit -> commit_buffer(st, repo, false)
        :magit_amend -> commit_buffer(st, repo, true)
        :magit_log -> log(st)
        :magit_push -> remote_op(st, repo, :push)
        :magit_pull -> remote_op(st, repo, :pull)
        :magit_checkout -> Editor.api(st, :prompt, {{:magit, &checkout/2}, "Checkout branch: ", ""})
        :magit_branch_create -> Editor.api(st, :prompt, {{:magit, &create_branch/2}, "Create and checkout branch: ", ""})
        :magit_discard when path != nil and section == :unstaged -> git(st, fn -> Git.restore(repo, [path]) end)
        :magit_stash -> stash(st, repo)
        :quit_special -> Editor.api(st, :quit_window, true)
        other -> Editor.do_action(st, other)
      end

    result
  end

  # The file at point, or on a section's heading every file in it.
  defp paths(_repo, _section, path) when path != nil, do: [path]

  defp paths(repo, section, nil) do
    s = Git.status(repo)

    case section do
      :untracked -> s.untracked
      :unstaged -> Enum.map(s.unstaged, &elem(&1, 0))
      :staged -> Enum.map(s.staged, &elem(&1, 0))
    end
  end

  # A git operation: the refreshed status, or what went wrong.
  defp git(st, op) do
    case op.() do
      {:error, reason} -> st |> refresh() |> Editor.api(:error, "git: #{inspect_reason(reason)}")
      _ -> refresh(st)
    end
  rescue
    e -> st |> refresh() |> Editor.api(:error, "git: #{Exception.message(e)}")
  end

  defp inspect_reason(r) when is_binary(r), do: r
  defp inspect_reason(r), do: inspect(r)

  defp refresh(st) do
    b = Editor.buf(st)
    {st, _} = if b.kind == :magit, do: Editor.api(st, :save_repo_buffers, b.meta.root), else: {st, []}
    b = Editor.buf(st)
    {l, c} = Editor.api(st, :cursor, nil)

    case b.kind do
      :magit -> render_status(st, b.meta.root, b.meta.expanded) |> Editor.api(:set_cursor, {l, c})
      _ -> st
    end
  end

  defp toggle(st, section, path) do
    b = Editor.buf(st)
    key = {section, path}
    expanded = if MapSet.member?(b.meta.expanded, key), do: MapSet.delete(b.meta.expanded, key), else: MapSet.put(b.meta.expanded, key)
    {l, c} = Editor.api(st, :cursor, nil)
    render_status(st, b.meta.root, expanded) |> Editor.api(:set_cursor, {l, c})
  end

  defp commit_buffer(st, repo, amend) do
    staged = Git.status(repo).staged

    if staged == [] and not amend do
      Editor.api(st, :error, "Nothing staged (use s to stage)")
    else
      path = Path.join([repo.git_dir, "COMMIT_EDITMSG"])
      initial = if amend, do: Git.last_message(repo), else: ""

      template =
        initial <>
          "\n# Please enter the commit message for your changes. Lines starting\n# with '#' will be ignored. Save and close (:wq or ZZ) to commit.\n#\n" <>
          Enum.map_join(staged, "\n", fn {p, how} -> "#\t#{how}: #{p}" end) <> "\n"

      File.write!(path, template)
      st = Editor.api(st, :visit, path)
      b = Editor.buf(st)
      b = %{Buffer.from_file(path) | id: b.id, kind: :commit, mode: "Git-Commit", meta: %{repo_root: repo.root, amend: amend}}
      st = Editor.api(st, :put_buf, b) |> Editor.api(:set_cursor, {0, 0})
      %{st | mode: :insert}
    end
  end

  @doc "Called after a COMMIT_EDITMSG buffer is saved."
  def commit_saved(st, b) do
    message =
      b
      |> Buffer.lines()
      |> Enum.reject(&String.starts_with?(&1, "#"))
      |> Enum.join("\n")
      |> String.trim()

    if message == "" do
      Editor.api(st, :error, "Aborting commit due to empty commit message")
    else
      repo = Git.Repo.open(b.meta.repo_root)

      case Git.commit(repo, message, amend: b.meta[:amend] || false) do
        {:ok, sha} -> Editor.api(st, :msg, "[#{Git.current_branch(repo)} #{String.slice(sha, 0, 7)}] #{message |> String.split("\n") |> hd()}")
        {:error, reason} -> Editor.api(st, :error, "commit failed: #{reason}")
      end
    end
  end

  defp remote_op(st, repo, op) do
    st = Editor.api(st, :msg, "#{if op == :push, do: "Pushing to", else: "Pulling from"} origin...")

    result =
      case op do
        :push -> Git.Remote.push(repo, "origin", Git.current_branch(repo))
        :pull -> Git.Remote.pull(repo, "origin", Git.current_branch(repo))
      end

    case result do
      {:ok, text} -> Editor.api(st, :msg, text) |> refresh()
      {:error, reason} -> Editor.api(st, :error, "#{op} failed: #{reason}")
    end
  end

  defp checkout(st, branch) do
    repo = Git.Repo.open(Editor.buf(st).meta.root)

    case Git.checkout(repo, branch) do
      :ok -> refresh(st) |> Editor.api(:msg, "Switched to branch '#{branch}'")
      {:error, r} -> Editor.api(st, :error, r)
    end
  end

  defp create_branch(st, branch) do
    repo = Git.Repo.open(Editor.buf(st).meta.root)

    with :ok <- Git.create_branch(repo, branch), :ok <- Git.checkout(repo, branch) do
      refresh(st) |> Editor.api(:msg, "Switched to a new branch '#{branch}'")
    else
      {:error, r} -> Editor.api(st, :error, r)
    end
  end

  # The user bound Z to magit-stash.
  defp stash(st, repo) do
    case Git.stash(repo) do
      {:ok, msg} -> refresh(st) |> Editor.api(:msg, msg)
      {:error, r} -> Editor.api(st, :error, r)
    end
  end
end
