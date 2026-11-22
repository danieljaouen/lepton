defmodule Lepton.Git do
  @moduledoc """
  Git, implemented in Elixir and compatible with upstream git's on-disk
  format (repositories can be moved between Lepton and any other git).

  This module holds the porcelain operations used by the `git` command
  and the editor's magit buffer; storage lives in `Lepton.Git.Object`,
  `Lepton.Git.Index` and `Lepton.Git.Pack`, networking in
  `Lepton.Git.Remote`.
  """

  alias Lepton.Git.{Config, Index, Object, Repo}

  # -- discovery -----------------------------------------------------------------------

  def root(nil), do: nil

  def root(dir) do
    cond do
      File.dir?(Path.join(dir, ".git")) -> dir
      dir in ["/", "."] or Path.dirname(dir) == dir -> nil
      true -> root(Path.dirname(dir))
    end
  end

  def branch(dir) do
    case root(dir) do
      nil -> nil
      r -> current_branch(Repo.open(r))
    end
  end

  @doc "Summary for the prompt (starship git_branch/git_status)."
  def prompt_info(cwd) do
    case root(cwd) do
      nil ->
        nil

      r ->
        repo = Repo.open(r)
        s = status(repo)
        count = fn list, how -> Enum.count(list, fn {_, h} -> h == how end) end
        {ahead, behind} = ahead_behind(repo)

        %{
          root: r,
          branch: current_branch(repo) || String.slice(head_sha(repo) || "", 0, 7),
          staged: length(s.staged),
          modified: count.(s.unstaged, :modified),
          deleted: count.(s.unstaged, :deleted) + count.(s.staged, :deleted),
          untracked: length(s.untracked),
          renamed: 0,
          conflicted: 0,
          ahead: ahead,
          behind: behind
        }
    end
  rescue
    _ -> nil
  end

  # -- refs --------------------------------------------------------------------------------

  def head_ref(repo) do
    case File.read(Path.join(repo.git_dir, "HEAD")) do
      {:ok, "ref: " <> ref} -> {:ref, String.trim(ref)}
      {:ok, sha} -> {:detached, String.trim(sha)}
      _ -> nil
    end
  end

  def current_branch(repo) do
    case head_ref(repo) do
      {:ref, "refs/heads/" <> b} -> b
      _ -> nil
    end
  end

  def head_sha(repo) do
    case head_ref(repo) do
      {:ref, ref} -> resolve_ref(repo, ref)
      {:detached, sha} -> sha
      nil -> nil
    end
  end

  def resolve_ref(repo, ref) do
    case File.read(Path.join(repo.git_dir, ref)) do
      {:ok, "ref: " <> other} -> resolve_ref(repo, String.trim(other))
      {:ok, sha} -> String.trim(sha)
      _ -> Map.get(packed_refs(repo), ref)
    end
  end

  def packed_refs(repo) do
    case File.read(Path.join(repo.git_dir, "packed-refs")) do
      {:ok, text} ->
        for line <- String.split(text, "\n", trim: true), not String.starts_with?(line, ["#", "^"]), into: %{} do
          [sha, ref] = String.split(line, " ", parts: 2)
          {ref, sha}
        end

      _ ->
        %{}
    end
  end

  def update_ref(repo, ref, sha) do
    path = Path.join(repo.git_dir, ref)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, sha <> "\n")
  end

  def update_head(repo, sha) do
    case head_ref(repo) do
      {:ref, ref} -> update_ref(repo, ref, sha)
      _ -> File.write!(Path.join(repo.git_dir, "HEAD"), sha <> "\n")
    end
  end

  def branches(repo) do
    loose =
      Path.wildcard(Path.join(repo.git_dir, "refs/heads/**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, Path.join(repo.git_dir, "refs/heads")))

    packed = for "refs/heads/" <> b <- Map.keys(packed_refs(repo)), do: b
    Enum.uniq(loose ++ packed) |> Enum.sort()
  end

  def remote_branches(repo) do
    loose =
      Path.wildcard(Path.join(repo.git_dir, "refs/remotes/**/*"))
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, Path.join(repo.git_dir, "refs/remotes")))

    packed = for "refs/remotes/" <> b <- Map.keys(packed_refs(repo)), do: b
    Enum.uniq(loose ++ packed) |> Enum.reject(&String.ends_with?(&1, "/HEAD")) |> Enum.sort()
  end

  @doc "Resolve a revision: sha prefix, branch, tag, HEAD, HEAD~N, HEAD^."
  def rev_parse(repo, rev) do
    case Regex.run(~r/^(.+?)(~(\d*)|\^+)$/, rev) do
      [_, base, "~" <> _, n] ->
        n = if n == "", do: 1, else: String.to_integer(n)
        with sha when is_binary(sha) <- rev_parse(repo, base), do: nth_parent(repo, sha, n)

      [_, base, carets] ->
        with sha when is_binary(sha) <- rev_parse(repo, base), do: nth_parent(repo, sha, String.length(carets))

      nil ->
        cond do
          rev == "HEAD" -> head_sha(repo)
          sha = resolve_ref(repo, "refs/heads/" <> rev) -> sha
          sha = resolve_ref(repo, "refs/tags/" <> rev) -> peel(repo, sha)
          sha = resolve_ref(repo, "refs/remotes/" <> rev) -> sha
          sha = resolve_ref(repo, rev) -> sha
          Regex.match?(~r/^[0-9a-f]{4,40}$/, rev) -> expand_sha(repo, rev)
          true -> nil
        end
    end
  end

  defp peel(repo, sha) do
    case Object.read(repo, sha) do
      {:ok, {:tag, content}} -> content |> String.split("\n") |> hd() |> String.replace_prefix("object ", "")
      _ -> sha
    end
  end

  defp nth_parent(_repo, sha, 0), do: sha

  defp nth_parent(repo, sha, n) do
    case read_commit(repo, sha).parents do
      [p | _] -> nth_parent(repo, p, n - 1)
      [] -> nil
    end
  end

  defp expand_sha(repo, prefix) when byte_size(prefix) == 40, do: if(Object.exists?(repo, prefix), do: prefix)

  defp expand_sha(repo, prefix) do
    dir = Path.join([repo.git_dir, "objects", String.slice(prefix, 0, 2)])
    rest = String.slice(prefix, 2..-1//1)

    case File.ls(dir) do
      {:ok, names} ->
        case Enum.filter(names, &String.starts_with?(&1, rest)) do
          [one] -> String.slice(prefix, 0, 2) <> one
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # -- trees ---------------------------------------------------------------------------------

  # A submodule's tree entry (a gitlink): the commit of another repository.
  @gitlink "160000"

  @doc "Is this a submodule's entry (tree mode, or index mode)?"
  def gitlink?(mode), do: mode in [@gitlink, 0o160000]

  # The submodules' paths in an index or flattened tree.
  defp gitlinks(entries) do
    for {path, e} <- entries, gitlink?(if(is_map(e), do: e.mode, else: elem(e, 0))), do: path
  end

  defp inside?(path, dirs), do: Enum.any?(dirs, &String.starts_with?(path, &1 <> "/"))

  def read_commit(repo, sha) do
    {:commit, content} = Object.read!(repo, sha)
    content |> Object.parse_commit() |> Map.put(:sha, sha)
  end

  @doc "Flatten a tree to %{path => {mode, sha}}."
  def flatten_tree(repo, sha, prefix \\ "") do
    {:tree, content} = Object.read!(repo, sha)

    content
    |> Object.parse_tree()
    |> Enum.reduce(%{}, fn {mode, name, s}, acc ->
      path = if prefix == "", do: name, else: prefix <> "/" <> name
      if mode == "40000", do: Map.merge(acc, flatten_tree(repo, s, path)), else: Map.put(acc, path, {mode, s})
    end)
  end

  def head_tree(repo) do
    case head_sha(repo) do
      nil -> %{}
      sha -> flatten_tree(repo, read_commit(repo, sha).tree)
    end
  end

  @doc "Write tree objects for an index; returns the root tree sha."
  def write_tree(repo, index) do
    files = for {path, e} <- index, do: {String.split(path, "/"), e}
    build_tree(repo, files)
  end

  defp build_tree(repo, files) do
    {blobs, dirs} = Enum.split_with(files, fn {parts, _} -> length(parts) == 1 end)

    blob_entries = for {[name], e} <- blobs, do: {Integer.to_string(e.mode, 8), name, e.sha}

    dir_entries =
      dirs
      |> Enum.group_by(fn {[d | _], _} -> d end, fn {[_ | rest], e} -> {rest, e} end)
      |> Enum.map(fn {d, children} -> {"40000", d, build_tree(repo, children)} end)

    Object.write(repo, :tree, Object.encode_tree(blob_entries ++ dir_entries))
  end

  # -- worktree ---------------------------------------------------------------------------

  @doc "Worktree files (relative paths), honouring .gitignore and core.excludesfile."
  def worktree_files(repo) do
    ignore = ignore_rules(repo)
    walk(repo.root, "", ignore)
  end

  defp walk(root, rel, ignore) do
    dir = if rel == "", do: root, else: Path.join(root, rel)

    case File.ls(dir) do
      {:ok, names} ->
        Enum.flat_map(Enum.sort(names), fn name ->
          path = if rel == "", do: name, else: rel <> "/" <> name
          full = Path.join(root, path)

          cond do
            name == ".git" -> []
            ignored?(ignore, path, File.dir?(full)) -> []
            File.dir?(full) and not symlink?(full) -> walk(root, path, ignore)
            true -> [path]
          end
        end)

      _ ->
        []
    end
  end

  defp symlink?(p), do: match?({:ok, %{type: :symlink}}, File.lstat(p))
  # There, or a symlink (whose target may not be: a dangling link is still a file to git).
  defp present?(p), do: File.exists?(p) or symlink?(p)

  defp ignore_rules(repo) do
    global = Config.get(Config.load(repo), "core", "excludesfile")
    global = global && String.replace_prefix(global, "~", System.get_env("HOME") || "/root")

    [Path.join(repo.root, ".gitignore"), Path.join(repo.git_dir, "info/exclude"), global]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(fn f ->
      case File.read(f) do
        {:ok, text} -> String.split(text, "\n")
        _ -> []
      end
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&compile_ignore/1)
  end

  defp compile_ignore(pattern) do
    {negate, pattern} = if String.starts_with?(pattern, "!"), do: {true, String.slice(pattern, 1..-1//1)}, else: {false, pattern}
    {dir_only, pattern} = if String.ends_with?(pattern, "/"), do: {true, String.trim_trailing(pattern, "/")}, else: {false, pattern}
    anchored = String.contains?(String.trim_leading(pattern, "/"), "/") or String.starts_with?(pattern, "/")
    pattern = String.trim_leading(pattern, "/")

    re =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*/", "(?:.*/)?")
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")

    re = if anchored, do: "^" <> re <> "$", else: "(?:^|/)" <> re <> "$"
    {Regex.compile!(re), negate, dir_only}
  end

  defp ignored?(rules, path, dir?) do
    Enum.reduce(rules, false, fn {re, negate, dir_only}, acc ->
      if (not dir_only or dir?) and Regex.match?(re, path), do: not negate, else: acc
    end)
  end

  defp blob_sha_of_file(full) do
    case File.lstat(full) do
      {:ok, %{type: :symlink}} -> {:ok, target} = File.read_link(full); Object.hash(:blob, target)
      _ -> Object.hash(:blob, File.read!(full))
    end
  end

  # -- status --------------------------------------------------------------------------------

  def status(repo) do
    index = Index.read(repo)
    head = head_tree(repo)
    subs = gitlinks(index)
    # Files inside a submodule's directory are the submodule's.
    files = Enum.reject(worktree_files(repo), &inside?(&1, subs))
    file_set = MapSet.new(files)

    staged =
      (for {path, e} <- index, not match?({_, sha} when sha == e.sha, head[path]) do
         {path, if(Map.has_key?(head, path), do: :modified, else: :"new file")}
       end ++ for(path <- Map.keys(head), not Map.has_key?(index, path), do: {path, :deleted}))
      |> Enum.sort()

    unstaged =
      for {path, e} <- Enum.sort(index), reduce: [] do
        acc ->
          full = Path.join(repo.root, path)

          cond do
            gitlink?(e.mode) -> acc
            not MapSet.member?(file_set, path) and not present?(full) -> acc ++ [{path, :deleted}]
            not present?(full) -> acc
            unchanged_stat?(full, e) -> acc
            blob_sha_of_file(full) != e.sha -> acc ++ [{path, :modified}]
            true -> acc
          end
      end

    untracked = Enum.reject(files, &Map.has_key?(index, &1))
    %{staged: staged, unstaged: unstaged, untracked: untracked}
  end

  defp unchanged_stat?(full, e) do
    case File.lstat(full, time: :posix) do
      {:ok, st} -> st.size == e.size and {st.mtime, 0} == e.mtime and e.size > 0
      _ -> false
    end
  end

  def clean?(repo) do
    s = status(repo)
    s.staged == [] and s.unstaged == []
  end

  # -- staging ------------------------------------------------------------------------------

  def add(repo, paths) do
    index = Index.read(repo)
    subs = gitlinks(index)
    files = Enum.reject(worktree_files(repo), &inside?(&1, subs))

    targets =
      Enum.flat_map(paths, fn p ->
        rel = normalize_path(repo, p)

        cond do
          rel in ["", "."] -> files ++ deleted_in_index(repo, index, "")
          true ->
            matched = Enum.filter(files, &(&1 == rel or String.starts_with?(&1, rel <> "/")))
            missing = if matched == [] and Map.has_key?(index, rel), do: [rel], else: []
            missing2 = deleted_in_index(repo, index, rel)
            matched ++ missing ++ missing2
        end
      end)
      |> Enum.uniq()

    index =
      Enum.reduce(targets, index, fn rel, idx ->
        full = Path.join(repo.root, rel)

        cond do
          rel in subs ->
            idx

          File.exists?(full) or symlink?(full) ->
            content = if symlink?(full), do: elem(File.read_link(full), 1), else: File.read!(full)
            sha = Object.write(repo, :blob, content)
            Map.put(idx, rel, Index.entry_for(full, rel, sha))

          true ->
            Map.delete(idx, rel)
        end
      end)

    Index.write(repo, index)
    {:ok, targets}
  end

  defp deleted_in_index(repo, index, prefix) do
    for {path, _} <- index,
        prefix == "" or path == prefix or String.starts_with?(path, prefix <> "/"),
        not present?(Path.join(repo.root, path)),
        do: path
  end

  def normalize_path(repo, p) do
    full = Path.expand(p, repo.root)
    if full == repo.root, do: "", else: Path.relative_to(full, repo.root)
  end

  def rm(repo, paths, cached \\ false) do
    index = Index.read(repo)

    index =
      Enum.reduce(paths, index, fn p, idx ->
        rel = normalize_path(repo, p)
        unless cached, do: File.rm(Path.join(repo.root, rel))
        Map.delete(idx, rel)
      end)

    Index.write(repo, index)
  end

  @doc "Reset index entries to HEAD (git restore --staged / reset PATH)."
  def unstage(repo, :all), do: unstage(repo, Map.keys(Index.read(repo)) ++ Map.keys(head_tree(repo)))

  def unstage(repo, paths) do
    head = head_tree(repo)
    index = Index.read(repo)

    index =
      Enum.reduce(paths, index, fn p, idx ->
        rel = normalize_path(repo, p)

        case head[rel] do
          nil -> Map.delete(idx, rel)
          {mode, sha} ->
            full = Path.join(repo.root, rel)
            base = if present?(full), do: Index.entry_for(full, rel, sha), else: %{path: rel, size: 0, mtime: {0, 0}}
            Map.put(idx, rel, %{base | sha: sha, mode: String.to_integer(mode, 8), mtime: {0, 0}})
        end
      end)

    Index.write(repo, index)
  end

  @doc "Discard worktree changes (git restore PATH)."
  def restore(repo, paths) do
    index = Index.read(repo)

    for p <- paths do
      rel = normalize_path(repo, p)

      case index[rel] do
        nil -> :ok
        e ->
          {:blob, content} = Object.read!(repo, e.sha)
          File.write!(Path.join(repo.root, rel), content)
      end
    end

    # Refresh stat info so status is fast and accurate.
    index = Map.new(index, fn {rel, e} ->
      full = Path.join(repo.root, rel)
      if rel in Enum.map(paths, &normalize_path(repo, &1)) and present?(full), do: {rel, Index.entry_for(full, rel, e.sha)}, else: {rel, e}
    end)

    Index.write(repo, index)
  end

  # -- commits ---------------------------------------------------------------------------------

  def identity(repo) do
    cfg = Config.load(repo)
    name = Config.get(cfg, "user", "name") || "root"
    email = Config.get(cfg, "user", "email") || "root@lepton"
    ts = System.os_time(:second)
    "#{name} <#{email}> #{ts} #{Lepton.Time.offset(Lepton.Time.local(ts))}"
  end

  def commit(repo, message, opts \\ []) do
    index = Index.read(repo)

    if index == %{} && !opts[:allow_empty] do
      {:error, "nothing to commit"}
    else
      tree = write_tree(repo, index)
      head = head_sha(repo)

      parents =
        cond do
          opts[:amend] && head -> read_commit(repo, head).parents
          head -> [head]
          true -> []
        end

      if !opts[:amend] && head && read_commit(repo, head).tree == tree && !opts[:allow_empty] do
        {:error, "nothing to commit, working tree clean"}
      else
        who = identity(repo)
        message = String.trim_trailing(message) <> "\n"
        body = ["tree #{tree}\n", Enum.map(parents, &"parent #{&1}\n"), "author #{who}\n", "committer #{who}\n", "\n", message]
        sha = Object.write(repo, :commit, IO.iodata_to_binary(body))
        update_head(repo, sha)
        {:ok, sha}
      end
    end
  end

  def last_message(repo) do
    case head_sha(repo) do
      nil -> ""
      sha -> read_commit(repo, sha).message
    end
  end

  def head_summary(repo) do
    branch = current_branch(repo) || "(detached)"

    case head_sha(repo) do
      nil -> "#{branch}  (no commits yet)"
      sha -> "#{branch}  #{String.slice(sha, 0, 7)} #{read_commit(repo, sha).subject}"
    end
  end

  def log(repo, n, from \\ nil) do
    case from || head_sha(repo) do
      nil -> []
      sha -> walk_log(repo, [sha], MapSet.new(), n, [])
    end
  end

  # Newest-first traversal (by commit time) across merges.
  defp walk_log(_repo, [], _seen, _n, acc), do: Enum.reverse(acc)
  defp walk_log(_repo, _queue, _seen, 0, acc), do: Enum.reverse(acc)

  defp walk_log(repo, queue, seen, n, acc) do
    commits = Enum.map(queue, &read_commit(repo, &1))
    newest = Enum.max_by(commits, & &1.time)
    rest = Enum.reject(queue, &(&1 == newest.sha))
    seen = MapSet.put(seen, newest.sha)
    parents = Enum.reject(newest.parents, &(MapSet.member?(seen, &1) or &1 in rest))
    walk_log(repo, rest ++ parents, seen, n - 1, [newest | acc])
  end

  def ahead_behind(repo) do
    with b when is_binary(b) <- current_branch(repo),
         local when is_binary(local) <- head_sha(repo),
         remote when is_binary(remote) <- resolve_ref(repo, "refs/remotes/origin/" <> b) do
      if local == remote do
        {0, 0}
      else
        l = log(repo, 200, local) |> MapSet.new(& &1.sha)
        r = log(repo, 200, remote) |> MapSet.new(& &1.sha)
        {MapSet.size(MapSet.difference(l, r)), MapSet.size(MapSet.difference(r, l))}
      end
    else
      _ -> {0, 0}
    end
  rescue
    _ -> {0, 0}
  end

  # -- diffs ----------------------------------------------------------------------------------

  defp blob(repo, sha) do
    {:blob, c} = Object.read!(repo, sha)
    c
  end

  # What a diff shows for an entry: the file, or for a submodule its
  # commit, as git does ("Subproject commit SHA").
  defp shown(repo, mode, sha), do: if(gitlink?(mode), do: "Subproject commit #{sha}\n", else: blob(repo, sha))

  def file_diff(repo, path, kind) do
    index = Index.read(repo)
    head = head_tree(repo)
    full = Path.join(repo.root, path)

    {old, new} =
      case kind do
        :untracked -> {"", File.read!(full)}
        :unstaged -> {(index[path] && shown(repo, index[path].mode, index[path].sha)) || "", if(File.regular?(full), do: File.read!(full), else: "")}
        :staged -> {(head[path] && shown(repo, elem(head[path], 0), elem(head[path], 1))) || "", (index[path] && shown(repo, index[path].mode, index[path].sha)) || ""}
      end

    Lepton.Diff.unified(old, new, "a/" <> path, "b/" <> path, header: "")
  end

  @doc "Full unified diff: :unstaged (worktree vs index) or :staged (index vs HEAD)."
  def diff_text(repo, kind, paths \\ []) do
    s = status(repo)

    entries =
      case kind do
        :unstaged -> s.unstaged
        :staged -> s.staged
      end

    entries
    |> Enum.filter(fn {p, _} -> paths == [] or Enum.any?(paths, &(p == &1 or String.starts_with?(p, &1 <> "/"))) end)
    |> Enum.map_join(fn {path, _} ->
      body = file_diff(repo, path, kind)
      if body == "", do: "", else: "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n" <> body
    end)
  end

  def commit_diff(repo, sha) do
    c = read_commit(repo, sha)
    new = flatten_tree(repo, c.tree)
    old = case c.parents do
      [p | _] -> flatten_tree(repo, read_commit(repo, p).tree)
      [] -> %{}
    end

    (Map.keys(new) ++ Map.keys(old))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_join(fn path ->
      a = if old[path], do: shown(repo, elem(old[path], 0), elem(old[path], 1)), else: ""
      b = if new[path], do: shown(repo, elem(new[path], 0), elem(new[path], 1)), else: ""
      body = Lepton.Diff.unified(a, b, "", "", header: "")
      if body == "", do: "", else: "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n" <> body
    end)
  end

  # -- branches & checkout ------------------------------------------------------------------------

  def create_branch(repo, name, start \\ nil) do
    cond do
      resolve_ref(repo, "refs/heads/" <> name) -> {:error, "a branch named '#{name}' already exists"}
      sha = start || head_sha(repo) -> update_ref(repo, "refs/heads/" <> name, sha); :ok
      true -> {:error, "not a valid object name: 'HEAD'"}
    end
  end

  def delete_branch(repo, name) do
    if current_branch(repo) == name do
      {:error, "cannot delete branch '#{name}' checked out"}
    else
      case File.rm(Path.join(repo.git_dir, "refs/heads/" <> name)) do
        :ok -> :ok
        _ -> {:error, "branch '#{name}' not found"}
      end
    end
  end

  def checkout(repo, target) do
    cond do
      resolve_ref(repo, "refs/heads/" <> target) ->
        with :ok <- switch_tree(repo, rev_parse(repo, target)) do
          File.write!(Path.join(repo.git_dir, "HEAD"), "ref: refs/heads/#{target}\n")
          :ok
        end

      remote = resolve_ref(repo, "refs/remotes/origin/" <> target) ->
        # Like git: create a local tracking branch from origin/<name>.
        with :ok <- switch_tree(repo, remote) do
          update_ref(repo, "refs/heads/" <> target, remote)
          File.write!(Path.join(repo.git_dir, "HEAD"), "ref: refs/heads/#{target}\n")
          Config.set(repo, "branch \"#{target}\"", "remote", "origin")
          Config.set(repo, "branch \"#{target}\"", "merge", "refs/heads/" <> target)
          :ok
        end

      sha = rev_parse(repo, target) ->
        with :ok <- switch_tree(repo, sha) do
          File.write!(Path.join(repo.git_dir, "HEAD"), sha <> "\n")
          :ok
        end

      true ->
        {:error, "pathspec '#{target}' did not match any file(s) known to git"}
    end
  end

  @doc "Make the worktree and index match commit `sha` (refuses to clobber changes)."
  def switch_tree(repo, sha, force \\ false) do
    if not force and not clean?(repo) do
      {:error, "Your local changes would be overwritten. Commit or stash them first."}
    else
      old = head_tree(repo)
      new = flatten_tree(repo, read_commit(repo, sha).tree)
      write_worktree(repo, old, new)
      :ok
    end
  end

  @doc """
  Make the worktree match tree `new`, given that it currently matches `old`.
  With `force`, every file of `new` is rewritten even if unchanged in the
  trees (discarding local modifications).
  """
  def write_worktree(repo, old, new, force \\ false) do
    for {path, _} <- old, not Map.has_key?(new, path) do
      File.rm(Path.join(repo.root, path))
      prune_empty(repo, Path.dirname(Path.join(repo.root, path)))
    end

    index =
      for {path, {mode, sha}} <- new, into: %{} do
        full = Path.join(repo.root, path)

        cond do
          # A submodule: its commit is another repository's. Like git
          # without --recurse-submodules, an empty directory stands for it.
          mode == @gitlink ->
            File.mkdir_p!(full)

          not force and match?({^mode, ^sha}, old[path]) and present?(full) ->
            :ok

          true ->
            File.mkdir_p!(Path.dirname(full))
            content = blob(repo, sha)

            if mode == "120000" do
              File.rm(full)
              File.ln_s(content, full)
            else
              File.write!(full, content)
              if mode == "100755", do: File.chmod(full, 0o755)
            end
        end

        {path, if(mode == @gitlink, do: Index.gitlink_entry(path, sha), else: Index.entry_for(full, path, sha))}
      end

    Index.write(repo, index)
  end

  defp prune_empty(repo, dir) do
    if dir != repo.root and File.ls(dir) == {:ok, []} do
      File.rmdir(dir)
      prune_empty(repo, Path.dirname(dir))
    end
  end

  def reset(repo, rev, mode) do
    case rev_parse(repo, rev) do
      nil -> {:error, "unknown revision '#{rev}'"}
      sha ->
        old = head_tree(repo)
        update_head(repo, sha)
        new = flatten_tree(repo, read_commit(repo, sha).tree)

        case mode do
          :hard -> write_worktree(repo, old, new, true)
          :mixed ->
            index = for {path, {mode, s}} <- new, into: %{}, do: {path, %{path: path, sha: s, mode: String.to_integer(mode, 8), size: 0, mtime: {0, 0}}}
            Index.write(repo, index)
          :soft -> :ok
        end

        :ok
    end
  end

  @doc "Fast-forward the current branch to `sha` if possible."
  def fast_forward(repo, sha) do
    head = head_sha(repo)

    cond do
      head == sha -> {:ok, "Already up to date."}
      head == nil ->
        :ok = switch_tree(repo, sha, true)
        update_head(repo, sha)
        {:ok, "Fast-forward"}

      Enum.any?(log(repo, 10_000, sha), &(&1.sha == head)) ->
        case switch_tree(repo, sha) do
          :ok -> update_head(repo, sha); {:ok, "Fast-forward #{String.slice(head, 0, 7)}..#{String.slice(sha, 0, 7)}"}
          err -> err
        end

      Enum.any?(log(repo, 10_000, head), &(&1.sha == sha)) ->
        {:ok, "Already up to date (local branch is ahead)."}

      true ->
        {:error, "Not possible to fast-forward; branches have diverged (merge is not supported yet)."}
    end
  end

  # -- stash ----------------------------------------------------------------------------------

  def stash(repo) do
    if clean?(repo) do
      {:error, "No local changes to save"}
    else
      head = head_sha(repo) || raise "You do not have the initial commit yet"
      index = Index.read(repo)
      index_tree = write_tree(repo, index)
      who = identity(repo)
      msg = "WIP on #{current_branch(repo)}: #{String.slice(head, 0, 7)} #{read_commit(repo, head).subject}"
      i_commit = Object.write(repo, :commit, "tree #{index_tree}\nparent #{head}\nauthor #{who}\ncommitter #{who}\n\nindex on #{msg}\n")

      # worktree tree: index plus modified tracked files
      wt =
        Enum.reduce(index, index, fn {path, e}, acc ->
          full = Path.join(repo.root, path)

          if File.exists?(full),
            do: Map.put(acc, path, %{e | sha: Object.write(repo, :blob, File.read!(full))}),
            else: Map.delete(acc, path)
        end)

      w_tree = write_tree(repo, wt)
      w_commit = Object.write(repo, :commit, "tree #{w_tree}\nparent #{head}\nparent #{i_commit}\nauthor #{who}\ncommitter #{who}\n\n#{msg}\n")
      update_ref(repo, "refs/stash", w_commit)
      tree = flatten_tree(repo, read_commit(repo, head).tree)
      write_worktree(repo, tree, tree, true)
      {:ok, "Saved working directory and index state #{msg}"}
    end
  end

  def stash_pop(repo) do
    case resolve_ref(repo, "refs/stash") do
      nil -> {:error, "No stash entries found."}
      sha ->
        c = read_commit(repo, sha)
        files = flatten_tree(repo, c.tree)

        for {path, {mode, s}} <- files, not gitlink?(mode) do
          full = Path.join(repo.root, path)
          File.mkdir_p!(Path.dirname(full))
          File.write!(full, blob(repo, s))
        end

        File.rm(Path.join(repo.git_dir, "refs/stash"))
        {:ok, "Dropped refs/stash (#{String.slice(sha, 0, 7)})"}
    end
  end

  def remote_url(repo, name), do: Config.get(Config.load(repo), "remote \"#{name}\"", "url")
end

defmodule Lepton.Git.Config do
  @moduledoc """
  git-config files: `~/.gitconfig` (with `[include] path = ...`, as the
  user's dotfiles use for `.gitconfig.local`) and `.git/config`.
  Stored as `%{"section" | "section \\"sub\\"" => %{key => value}}`; keys
  are case-insensitive.
  """

  def parse(text, base_dir \\ nil) do
    {cfg, _} =
      text
      |> String.split("\n")
      |> Enum.reduce({%{}, nil}, fn raw, {cfg, section} ->
        line = raw |> String.trim() |> strip_comment()

        cond do
          line == "" ->
            {cfg, section}

          m = Regex.run(~r/^\[\s*([A-Za-z0-9.\-]+)(?:\s+"([^"]*)")?\s*\]$/, line) ->
            sec = case m do
              [_, s, sub] -> "#{String.downcase(s)} \"#{sub}\""
              [_, s] -> String.downcase(s)
            end

            {Map.put_new(cfg, sec, %{}), sec}

          section != nil ->
            {k, v} =
              case String.split(line, "=", parts: 2) do
                [k, v] -> {String.trim(k) |> String.downcase(), unquote_value(String.trim(v))}
                [k] -> {String.trim(k) |> String.downcase(), "true"}
              end

            cfg = Map.update(cfg, section, %{k => v}, &Map.put(&1, k, v))
            cfg = if section == "include" and k == "path" and base_dir, do: include(cfg, Path.expand(v, base_dir)), else: cfg
            {cfg, section}

          true ->
            {cfg, section}
        end
      end)

    cfg
  end

  defp include(cfg, path) do
    case File.read(path) do
      {:ok, text} -> deep_merge(cfg, parse(text, Path.dirname(path)))
      _ -> cfg
    end
  end

  defp deep_merge(a, b), do: Map.merge(a, b, fn _k, x, y -> Map.merge(x, y) end)

  defp strip_comment(line) do
    if String.starts_with?(line, ["#", ";"]), do: "", else: Regex.replace(~r/\s+[#;](?=(?:[^"]*"[^"]*")*[^"]*$).*$/, line, "")
  end

  defp unquote_value("\"" <> rest), do: rest |> String.trim_trailing("\"") |> String.replace("\\\"", "\"")
  defp unquote_value(v), do: v

  def global(home \\ nil) do
    home = home || System.get_env("HOME") || "/root"
    path = Path.join(home, ".gitconfig")

    case File.read(path) do
      {:ok, text} -> parse(text, home)
      _ -> %{}
    end
  end

  def load(repo) do
    local =
      case File.read(Path.join(repo.git_dir, "config")) do
        {:ok, text} -> parse(text, repo.git_dir)
        _ -> %{}
      end

    deep_merge(global(), local)
  end

  def get(cfg, section, key), do: cfg |> Map.get(section, %{}) |> Map.get(String.downcase(key))
  def section(cfg, section), do: Map.get(cfg, section, %{}) |> Enum.sort()

  @doc "Set a key in the repository's .git/config."
  def set(repo, section, key, value) do
    path = Path.join(repo.git_dir, "config")
    cfg = case File.read(path) do
      {:ok, text} -> parse(text)
      _ -> %{}
    end

    cfg = Map.update(cfg, section, %{key => value}, &Map.put(&1, key, value))
    File.write!(path, encode(cfg))
  end

  def set_global(home, section, key, value) do
    path = Path.join(home, ".gitconfig")
    text = case File.read(path) do
      {:ok, t} -> t
      _ -> ""
    end

    # Append to preserve the user's file layout and comments.
    File.write!(path, text <> "\n[#{section}]\n\t#{key} = #{value}\n")
  end

  def encode(cfg) do
    Enum.map_join(cfg, fn {section, kvs} ->
      header =
        case String.split(section, " ", parts: 2) do
          [s, sub] -> "[#{s} #{sub}]"
          [s] -> "[#{s}]"
        end

      header <> "\n" <> Enum.map_join(kvs, fn {k, v} -> "\t#{k} = #{v}\n" end)
    end)
  end
end
