defmodule Lepton.Commands.Dev do
  @moduledoc "Development tools: editor, multiplexer, git, gh, Elixir, the shell and the self-test runner."

  use Lepton.Command
  alias Lepton.Git
  alias Lepton.Git.{Config, Remote, Repo}

  # -- editor & multiplexer ---------------------------------------------------------------

  defcmd "le", "the Lepton editor (Spacemacs keybindings from your dotfiles)",
    usage: "le [FILE...]",
    aliases: ["vi", "vim", "nvim", "emacs", "emacsclient", "spacemacs", "edit"] do
    files = Enum.reject(args, &String.starts_with?(&1, ["-", "+"]))

    if ctx.tty do
      Lepton.Editor.run(files, ctx)
    else
      IO.err(ctx, "le: not a terminal")
      1
    end
  end

  defcmd "tmux", "terminal multiplexer (key table from ~/.tmux.conf)", usage: "tmux [new [-s NAME] | attach [-t NAME] | ls | kill-session -t NAME | list-keys]" do
    Lepton.Mux.cli(args, ctx)
  end

  # -- shells ---------------------------------------------------------------------------------

  defcmd "lsh", "the Lepton shell", usage: "lsh [-c COMMANDS | SCRIPT [ARG...]]", aliases: ["sh", "zsh", "bash"] do
    case args do
      ["-c", src | rest] ->
        Lepton.Shell.run_string(src, cwd: ctx.cwd, env: ctx.env, stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr, tty: ctx.tty, args: rest, user: ctx.user)

      [file | rest] ->
        shell = Lepton.Shell.new(ctx, args: rest, name: file)
        Lepton.Shell.run_file(Ctx.path(ctx, file), rest, shell)

      [] ->
        if ctx.tty, do: Lepton.Shell.interactive(ctx), else: Lepton.Shell.run_string(IO.read_all(ctx.stdin), cwd: ctx.cwd, env: ctx.env, stdout: ctx.stdout, user: ctx.user)
    end
  end

  # -- Elixir ---------------------------------------------------------------------------------

  defcmd "iex", "interactive Elixir (loads ~/.iex.exs)", usage: "iex" do
    Lepton.IEx.run(ctx)
  end

  defcmd "elixir", "run Elixir code", usage: "elixir [-e CODE] [FILE.exs] [ARGS...]" do
    case args do
      ["-e", code | rest] -> eval(ctx, code, rest, "nofile")
      ["-v" | _] -> IO.puts(ctx, "Erlang/OTP #{System.otp_release()} [erts-#{:erlang.system_info(:version)}]\n\nElixir #{System.version()}"); 0
      [file | rest] ->
        case File.read(Ctx.path(ctx, file)) do
          {:ok, code} -> eval(ctx, code, rest, file)
          {:error, r} -> IO.err(ctx, "elixir: #{file}: #{:file.format_error(r)}"); 1
        end

      [] -> IO.err(ctx, "usage: elixir [-e CODE] [FILE.exs]"); 1
    end
  end

  defp eval(ctx, code, args, file) do
    System.argv(args)
    Code.eval_string(code, [args: args, ctx: ctx], file: file)
    0
  rescue
    e ->
      IO.err(ctx, Exception.format(:error, e, __STACKTRACE__) |> String.trim_trailing())
      1
  end

  defcmd "mix", "Elixir's build tool, in a VM of its own: projects, Hex, Phoenix (mix phx.new, mix phx.server)", usage: "mix [TASK [ARGS...]]" do
    Lepton.MixVM.run(args, ctx)
  end

  defcmd "claude", "Claude Code, Anthropic's coding agent (install it with: sudo claude-code install)",
    usage: "claude [OPTIONS] [PROMPT] | claude -p PROMPT" do
    Lepton.ClaudeCode.run(args, ctx)
  end

  defcmd "claude-code", "install, update, remove or show Claude Code (Anthropic's build, downloaded from Anthropic)",
    usage: "claude-code [status] | install | update | remove" do
    claude_code(args, ctx)
  end

  defcmd "erl", "Erlang version information", usage: "erl" do
    IO.puts(ctx, "Erlang/OTP #{System.otp_release()} [erts-#{:erlang.system_info(:version)}] [#{:erlang.system_info(:system_architecture)}] [smp:#{System.schedulers_online()}]")
    0
  end

  # -- self tests -----------------------------------------------------------------------------

  defcmd "lepton-test", "run the Lepton self-test suite (ExUnit, inside the OS)", usage: "lepton-test [--only TAG] [FILE...]" do
    Lepton.SelfTest.run(args, ctx)
  end

  # -- GitHub CLI -----------------------------------------------------------------------------

  defcmd "gh", "GitHub CLI (repos, issues, PRs, auth)", usage: "gh auth login|status|token|logout | repo view|list|clone|create | ssh-key list|add | config get|set git_protocol | issue list|view|create | pr list|view | browse | api PATH" do
    Lepton.GH.run(args, ctx)
  end

  # -- git --------------------------------------------------------------------------------------

  defcmd "git", "distributed version control, with HTTPS and SSH remotes (Elixir implementation)", usage: "git COMMAND [ARGS]" do
    git(args, ctx)
  end

  @doc false
  def git(args, ctx) do
    {args, ctx} = git_global_opts(args, ctx)

    case args do
      [] -> git_usage(ctx)
      [cmd | rest] ->
        aliases = ctx |> Ctx.home() |> Config.global() |> Config.section("alias") |> Map.new()

        case Map.fetch(aliases, cmd) do
          {:ok, "!" <> shell} ->
            Lepton.Shell.run_string(shell <> " " <> Enum.join(rest, " "), cwd: ctx.cwd, env: ctx.env, stdout: ctx.stdout, stderr: ctx.stderr, user: ctx.user)

          {:ok, expansion} ->
            git(split_alias(expansion) ++ rest, ctx)

          :error ->
            since = System.os_time(:second)
            status = git_cmd(cmd, rest, ctx)
            adopt_git(cmd, ctx, since)
            status
        end
    end
  rescue
    e ->
      IO.err(ctx, "fatal: #{Exception.message(e)}")
      128
  end

  defp git_global_opts(["-C", dir | rest], ctx), do: git_global_opts(rest, %{ctx | cwd: Ctx.path(ctx, dir)})
  defp git_global_opts(["--no-pager" | rest], ctx), do: git_global_opts(rest, ctx)
  defp git_global_opts(args, ctx), do: {args, ctx}

  # Split an alias like a shell would: --pretty='format:%h %s' is one word.
  defp split_alias(text) do
    case Lepton.Shell.Parser.tokenize(text) do
      {:ok, tokens} ->
        for {:word, parts} <- tokens do
          Enum.map_join(parts, fn
            {:lit, t} -> t
            {:sq, t} -> t
            {:dq, ps} -> Enum.map_join(ps, fn {:lit, t} -> t; _ -> "" end)
            {:var, n} -> "$" <> n
            :tilde -> "~"
            _ -> ""
          end)
        end

      _ ->
        String.split(text)
    end
  end

  defp repo!(ctx) do
    case Git.root(ctx.cwd) do
      nil -> raise "not a git repository (or any of the parent directories): .git"
      root -> Repo.open(root)
    end
  end

  defp color(ctx, code, text), do: if(Lepton.Style.color?(ctx) and Lepton.TTY.tty?(ctx.stdout), do: "\e[#{code}m#{text}\e[0m", else: text)

  # Git writes as root: what a command wrote in the repository (objects,
  # the index, checked-out files) is the user's. Commands that only read
  # are skipped (the walk costs a look at every file).
  @git_readers ~w(status log diff show blame help version ls-files rev-parse clone)

  defp adopt_git(cmd, ctx, since) do
    if cmd not in @git_readers and ctx.user not in [nil, "root"] do
      if root = Lepton.Git.root(ctx.cwd), do: Lepton.Users.adopt(ctx, root, since)
    end
  end

  defp git_cmd("init", rest, ctx) do
    {opts, dirs} = getopt(rest, "b:q")
    dir = Ctx.path(ctx, List.first(dirs) || ".")
    Lepton.Users.own_new(ctx, dir, fn -> File.mkdir_p!(dir) end)
    existed = File.dir?(Path.join(dir, ".git"))
    branch = opts["b"] || opts["initial-branch"] || "main"
    unless existed, do: Lepton.Users.own_new(ctx, Path.join(dir, ".git"), fn -> Repo.init(dir, branch) end)
    unless opts["q"], do: IO.puts(ctx, "#{if existed, do: "Reinitialized existing", else: "Initialized empty"} Git repository in #{Path.join(dir, ".git")}/")
    0
  end

  defp git_cmd("status", rest, ctx) do
    repo = repo!(ctx)
    s = Git.status(repo)
    {opts, _} = getopt(rest, "sb")

    if opts["s"] || opts["short"] do
      for {p, how} <- s.staged, do: IO.puts(ctx, color(ctx, "32", short(how)) <> "  " <> p)
      for {p, how} <- s.unstaged, do: IO.puts(ctx, " " <> color(ctx, "31", short(how)) <> " " <> p)
      for p <- s.untracked, do: IO.puts(ctx, color(ctx, "31", "??") <> " " <> p)
    else
      IO.puts(ctx, "On branch #{Git.current_branch(repo) || "(detached HEAD)"}")
      {ahead, behind} = Git.ahead_behind(repo)
      if ahead > 0, do: IO.puts(ctx, "Your branch is ahead of 'origin/#{Git.current_branch(repo)}' by #{ahead} commit#{if ahead > 1, do: "s"}.")
      if behind > 0, do: IO.puts(ctx, "Your branch is behind 'origin/#{Git.current_branch(repo)}' by #{behind} commit#{if behind > 1, do: "s"}.")
      if Git.head_sha(repo) == nil, do: IO.puts(ctx, "\nNo commits yet")

      section = fn title, hint, entries, code ->
        if entries != [] do
          IO.puts(ctx, "\n#{title}:\n  (#{hint})")
          for {p, how} <- entries, do: IO.puts(ctx, color(ctx, code, "\t#{String.pad_trailing("#{how}:", 12)}#{p}"))
        end
      end

      section.("Changes to be committed", "use \"git restore --staged <file>...\" to unstage", s.staged, "32")
      section.("Changes not staged for commit", "use \"git add <file>...\" to update what will be committed", s.unstaged, "31")

      if s.untracked != [] do
        IO.puts(ctx, "\nUntracked files:\n  (use \"git add <file>...\" to include in what will be committed)")
        for p <- s.untracked, do: IO.puts(ctx, color(ctx, "31", "\t" <> p))
      end

      if s.staged == [] and s.unstaged == [] and s.untracked == [], do: IO.puts(ctx, "nothing to commit, working tree clean")
    end

    0
  end

  defp git_cmd("add", rest, ctx) do
    repo = repo!(ctx)
    {_opts, paths} = getopt(rest, "Auv")
    paths = if paths == [] or "-A" in rest or "--all" in rest, do: (if paths == [], do: ["."], else: paths), else: paths
    paths = Enum.map(paths, &Path.relative_to(Ctx.path(ctx, &1), repo.root)) |> Enum.map(&if(&1 == repo.root, do: ".", else: &1))
    {:ok, _} = Git.add(repo, Enum.map(paths, &Path.join(repo.root, &1)))
    0
  end

  defp git_cmd("rm", rest, ctx) do
    repo = repo!(ctx)
    {opts, paths} = getopt(rest, "rf")
    Git.rm(repo, Enum.map(paths, &Ctx.path(ctx, &1)), opts["cached"] == true)
    for p <- paths, do: IO.puts(ctx, "rm '#{p}'")
    0
  end

  defp git_cmd("commit", rest, ctx) do
    repo = repo!(ctx)
    {opts, _} = getopt(rest, "m:aF:")
    if opts["a"] || opts["all"], do: Git.add(repo, for({p, _} <- Git.status(repo).unstaged, do: Path.join(repo.root, p)))

    message =
      cond do
        m = opts["m"] || opts["message"] -> m
        f = opts["F"] -> File.read!(Ctx.path(ctx, f))
        opts["amend"] -> Git.last_message(repo)
        true -> edit_message(ctx, repo)
      end

    if String.trim(message || "") == "" do
      IO.err(ctx, "Aborting commit due to empty commit message.")
      1
    else
      case Git.commit(repo, message, amend: opts["amend"] == true, allow_empty: opts["allow-empty"] == true) do
        {:ok, sha} ->
          files = length(Git.commit_diff(repo, sha) |> String.split("diff --git") |> tl())
          IO.puts(ctx, "[#{Git.current_branch(repo) || "detached HEAD"} #{String.slice(sha, 0, 7)}] #{message |> String.split("\n") |> hd()}")
          IO.puts(ctx, " #{files} file#{if files == 1, do: "", else: "s"} changed")
          0

        {:error, msg} ->
          IO.puts(ctx, msg)
          1
      end
    end
  end

  defp git_cmd("log", rest, ctx) do
    repo = repo!(ctx)
    {opts, revs} = getopt(rest, "n:p")
    n = Lepton.Args.int(opts, "n", Lepton.Args.int(opts, "#", 1_000_000))
    start = case revs do
      [rev | _] -> Git.rev_parse(repo, rev)
      [] -> nil
    end

    commits =
      if opts["all"] do
        tips = (Git.branches(repo) |> Enum.map(&Git.resolve_ref(repo, "refs/heads/" <> &1))) ++ (Git.remote_branches(repo) |> Enum.map(&Git.resolve_ref(repo, "refs/remotes/" <> &1)))
        tips |> Enum.reject(&is_nil/1) |> Enum.flat_map(&Git.log(repo, n, &1)) |> Enum.uniq_by(& &1.sha) |> Enum.sort_by(& &1.time, :desc) |> Enum.take(n)
      else
        Git.log(repo, n, start)
      end

    decorations = decorations(repo)
    graph = opts["graph"] == true
    patch = opts["p"] == true

    format =
      cond do
        opts["oneline"] -> "%C(yellow)%h%Creset %s%d"
        pretty = opts["pretty"] || opts["format"] -> pretty |> String.replace_prefix("format:", "") |> String.replace_prefix("tformat:", "")
        true -> :medium
      end

    for c <- commits do
      prefix = if graph, do: color(ctx, "31", "* "), else: ""

      text =
        case format do
          :medium ->
            date = git_date(c)
            color(ctx, "33", "commit #{c.sha}") <> decoration_text(ctx, decorations[c.sha], true) <> "\nAuthor: #{c.author_name} <#{c.author_email}>\nDate:   #{date}\n\n" <> (c.message |> String.trim_trailing() |> String.split("\n") |> Enum.map_join("\n", &("    " <> &1))) <> "\n"

          fmt ->
            pretty_format(ctx, fmt, c, decorations[c.sha])
        end

      lines = String.split(text, "\n")
      body = [prefix <> hd(lines) | Enum.map(tl(lines), &((if graph, do: color(ctx, "31", "| "), else: "") <> &1))] |> Enum.join("\n")
      IO.puts(ctx, body)
      if patch, do: IO.write(ctx, Lepton.Diff.colorize(Git.commit_diff(repo, c.sha), Lepton.Style.color?(ctx)) <> "\n")
    end

    0
  end

  defp git_cmd("show", rest, ctx) do
    repo = repo!(ctx)
    sha = Git.rev_parse(repo, List.first(rest) || "HEAD") || raise "bad revision"
    git_cmd("log", ["-n", "1", sha], ctx)
    IO.write(ctx, "\n" <> Lepton.Diff.colorize(Git.commit_diff(repo, sha), Lepton.Style.color?(ctx) and Lepton.TTY.tty?(ctx.stdout)))
    0
  end

  defp git_cmd("diff", rest, ctx) do
    repo = repo!(ctx)
    {opts, paths} = getopt(rest, "")
    kind = if opts["cached"] || opts["staged"], do: :staged, else: :unstaged
    paths = Enum.map(paths, &Path.relative_to(Ctx.path(ctx, &1), repo.root))
    IO.write(ctx, Lepton.Diff.colorize(Git.diff_text(repo, kind, paths), Lepton.Style.color?(ctx) and Lepton.TTY.tty?(ctx.stdout)))
    0
  end

  defp git_cmd("branch", rest, ctx) do
    repo = repo!(ctx)
    {opts, names} = getopt(rest, "dDarvm")

    cond do
      opts["d"] || opts["D"] ->
        Enum.reduce(names, 0, fn n, st ->
          case Git.delete_branch(repo, n) do
            :ok -> IO.puts(ctx, "Deleted branch #{n}."); st
            {:error, e} -> IO.err(ctx, "error: #{e}"); 1
          end
        end)

      names != [] ->
        case Git.create_branch(repo, hd(names), if(length(names) > 1, do: Git.rev_parse(repo, Enum.at(names, 1)))) do
          :ok -> 0
          {:error, e} -> IO.err(ctx, "fatal: #{e}"); 128
        end

      true ->
        current = Git.current_branch(repo)
        for b <- Git.branches(repo), do: IO.puts(ctx, if(b == current, do: "* " <> color(ctx, "32", b), else: "  " <> b))
        if opts["a"] || opts["r"], do: for(b <- Git.remote_branches(repo), do: IO.puts(ctx, "  " <> color(ctx, "31", "remotes/" <> b)))
        0
    end
  end

  defp git_cmd(cmd, rest, ctx) when cmd in ["checkout", "switch"] do
    repo = repo!(ctx)
    {opts, args} = getopt(rest, "b:c:")

    cond do
      new = opts["b"] || opts["c"] ->
        with :ok <- Git.create_branch(repo, new, if(args != [], do: Git.rev_parse(repo, hd(args)))),
             :ok <- Git.checkout(repo, new) do
          IO.puts(ctx, "Switched to a new branch '#{new}'")
          0
        else
          {:error, e} -> IO.err(ctx, "fatal: #{e}"); 128
        end

      true ->
        checkout_args(repo, cmd, args, ctx)
    end
  end

  defp git_cmd("restore", rest, ctx) do
    repo = repo!(ctx)
    {opts, paths} = getopt(rest, "S")
    paths = Enum.map(paths, &Ctx.path(ctx, &1))
    if opts["staged"] || opts["S"], do: Git.unstage(repo, paths), else: Git.restore(repo, paths)
    0
  end

  defp git_cmd("reset", rest, ctx) do
    repo = repo!(ctx)
    {opts, args} = getopt(rest, "q")

    cond do
      args != [] && !(opts["hard"] || opts["soft"] || opts["mixed"]) && Git.rev_parse(repo, hd(args)) == nil ->
        Git.unstage(repo, Enum.map(args, &Ctx.path(ctx, &1)))
        0

      true ->
        mode = cond do
          opts["hard"] -> :hard
          opts["soft"] -> :soft
          true -> :mixed
        end

        case Git.reset(repo, List.first(args) || "HEAD", mode) do
          :ok -> if mode == :hard, do: IO.puts(ctx, "HEAD is now at #{Git.head_summary(repo)}"); 0
          {:error, e} -> IO.err(ctx, "fatal: #{e}"); 128
        end
    end
  end

  defp git_cmd("stash", rest, ctx) do
    repo = repo!(ctx)

    result = case rest do
      ["pop" | _] -> Git.stash_pop(repo)
      _ -> Git.stash(repo)
    end

    case result do
      {:ok, msg} -> IO.puts(ctx, msg); 0
      {:error, e} -> IO.puts(ctx, e); 1
    end
  end

  defp git_cmd("ls-files", rest, ctx) do
    repo = repo!(ctx)

    cond do
      "-o" in rest or "--others" in rest ->
        for p <- Git.status(repo).untracked, do: IO.puts(ctx, p)

      true ->
        for {p, _} <- Enum.sort(Lepton.Git.Index.read(repo)), do: IO.puts(ctx, p)
    end

    0
  end

  defp git_cmd("rev-parse", rest, ctx) do
    repo = repo!(ctx)

    case rest do
      ["--show-toplevel"] -> IO.puts(ctx, repo.root)
      ["--abbrev-ref", "HEAD"] -> IO.puts(ctx, Git.current_branch(repo) || "HEAD")
      ["--git-dir"] -> IO.puts(ctx, repo.git_dir)
      revs -> for r <- revs, do: IO.puts(ctx, Git.rev_parse(repo, r) || raise("ambiguous argument '#{r}'"))
    end

    0
  end

  defp git_cmd("cat-file", [flag, rev], ctx) do
    repo = repo!(ctx)
    sha = Git.rev_parse(repo, rev) || raise "Not a valid object name #{rev}"
    {type, content} = Lepton.Git.Object.read!(repo, sha)

    case flag do
      "-t" -> IO.puts(ctx, to_string(type))
      "-s" -> IO.puts(ctx, to_string(byte_size(content)))
      "-p" when type == :tree ->
        for {mode, name, s} <- Lepton.Git.Object.parse_tree(content) do
          kind = if mode == "40000", do: "tree", else: "blob"
          IO.puts(ctx, "#{String.pad_leading(mode, 6, "0")} #{kind} #{s}\t#{name}")
        end

      _ -> IO.write(ctx, content)
    end

    0
  end

  defp git_cmd("hash-object", rest, ctx) do
    {opts, files} = getopt(rest, "w")

    for f <- files do
      content = File.read!(Ctx.path(ctx, f))
      sha = if opts["w"], do: Lepton.Git.Object.write(repo!(ctx), :blob, content), else: Lepton.Git.Object.hash(:blob, content)
      IO.puts(ctx, sha)
    end

    0
  end

  defp git_cmd("tag", rest, ctx) do
    repo = repo!(ctx)

    case rest do
      [] -> for t <- Path.wildcard(Path.join(repo.git_dir, "refs/tags/*")), do: IO.puts(ctx, Path.basename(t))
      [name | rev] -> Git.update_ref(repo, "refs/tags/" <> name, Git.rev_parse(repo, List.first(rev) || "HEAD"))
    end

    0
  end

  defp git_cmd("remote", rest, ctx) do
    repo = repo!(ctx)
    cfg = Config.load(repo)

    case rest do
      ["add", name, url] ->
        Config.set(repo, "remote \"#{name}\"", "url", url)
        Config.set(repo, "remote \"#{name}\"", "fetch", "+refs/heads/*:refs/remotes/#{name}/*")
        0

      ["set-url", name, url] ->
        Config.set(repo, "remote \"#{name}\"", "url", url)
        0

      ["-v" | _] ->
        for {"remote \"" <> rest, kv} <- cfg, name = String.trim_trailing(rest, "\""), url = kv["url"] do
          IO.puts(ctx, "#{name}\t#{url} (fetch)\n#{name}\t#{url} (push)")
        end

        0

      _ ->
        for {"remote \"" <> rest, _} <- cfg, do: IO.puts(ctx, String.trim_trailing(rest, "\""))
        0
    end
  end

  defp git_cmd("config", rest, ctx) do
    {opts, args} = getopt(rest, "l")
    home = Ctx.home(ctx)

    case args do
      [] when is_map_key(opts, "l") or is_map_key(opts, "list") ->
        cfg = if opts["global"], do: Config.global(home), else: (if Git.root(ctx.cwd), do: Config.load(repo!(ctx)), else: Config.global(home))
        for {section, kvs} <- Enum.sort(cfg), {k, v} <- Enum.sort(kvs), do: IO.puts(ctx, "#{config_key(section)}.#{k}=#{v}")
        0

      [key] ->
        {section, k} = split_key(key)
        cfg = if Git.root(ctx.cwd), do: Config.load(repo!(ctx)), else: Config.global(home)

        case Config.get(cfg, section, k) do
          nil -> 1
          v -> IO.puts(ctx, v); 0
        end

      [key, value] ->
        {section, k} = split_key(key)
        if opts["global"], do: Config.set_global(home, section, k, value), else: Config.set(repo!(ctx), section, k, value)
        0

      _ ->
        1
    end
  end

  defp git_cmd("clone", rest, ctx) do
    {_opts, args} = getopt(rest, "b:q")

    case args do
      [url | dir] ->
        url = expand_github_shorthand(url)
        dest = Ctx.path(ctx, List.first(dir) || url |> Path.basename() |> String.replace_suffix(".git", ""))
        IO.puts(ctx, "Cloning into '#{Path.basename(dest)}'...")

        case Remote.clone(url, dest, home: Ctx.home(ctx), env: ctx.env) do
          {:ok, msg} -> Lepton.Users.own(ctx, dest); IO.puts(ctx, msg); 0
          {:error, e} -> IO.err(ctx, "fatal: #{e}"); 128
        end

      [] ->
        IO.err(ctx, "usage: git clone URL [DIR]")
        129
    end
  end

  defp git_cmd("fetch", rest, ctx) do
    repo = repo!(ctx)

    case Remote.fetch(repo, List.first(rest) || "origin", home: Ctx.home(ctx), env: ctx.env) do
      {:ok, msg} -> IO.puts(ctx, msg); 0
      {:error, e} -> IO.err(ctx, "fatal: #{e}"); 128
    end
  end

  defp git_cmd("pull", rest, ctx) do
    repo = repo!(ctx)
    remote = List.first(rest) || "origin"

    case Remote.pull(repo, remote, Enum.at(rest, 1) || Git.current_branch(repo), home: Ctx.home(ctx), env: ctx.env) do
      {:ok, msg} -> IO.puts(ctx, msg); 0
      {:error, e} -> IO.err(ctx, "fatal: #{e}"); 1
    end
  end

  defp git_cmd("push", rest, ctx) do
    repo = repo!(ctx)
    {opts, args} = getopt(rest, "uf")
    remote = List.first(args) || "origin"
    branch = Enum.at(args, 1) || Git.current_branch(repo)

    case Remote.push(repo, remote, branch, force: opts["f"] == true || opts["force"] == true, home: Ctx.home(ctx), env: ctx.env) do
      {:ok, msg} ->
        if opts["u"] || opts["set-upstream"] do
          Config.set(repo, "branch \"#{branch}\"", "remote", remote)
          Config.set(repo, "branch \"#{branch}\"", "merge", "refs/heads/" <> branch)
        end

        IO.puts(ctx, msg)
        0

      {:error, e} ->
        IO.err(ctx, "error: #{e}")
        1
    end
  end

  defp git_cmd("merge", [rev | _], ctx) do
    repo = repo!(ctx)

    case Git.fast_forward(repo, Git.rev_parse(repo, rev) || raise("#{rev} - not something we can merge")) do
      {:ok, msg} -> IO.puts(ctx, msg); 0
      {:error, e} -> IO.err(ctx, e); 1
    end
  end

  defp git_cmd("ls-remote", [url | _], ctx) do
    home = Ctx.home(ctx)
    url = url |> expand_github_shorthand() |> Remote.rewrite_url(Config.global(home))

    case Remote.ls_remote(url, "git-upload-pack", home: home, env: ctx.env) do
      {:ok, refs, _} -> for {ref, sha} <- refs, do: IO.puts(ctx, "#{sha}\t#{ref}"); 0
      {:error, e} -> IO.err(ctx, "fatal: #{e}"); 128
    end
  end

  defp git_cmd("version", _, ctx), do: (IO.puts(ctx, "git version 2.45.0 (lepton, Elixir #{System.version()})"); 0)
  defp git_cmd("--version", _, ctx), do: git_cmd("version", [], ctx)
  defp git_cmd("help", _, ctx), do: git_usage(ctx)

  defp git_cmd(cmd, _rest, ctx) do
    IO.err(ctx, "git: '#{cmd}' is not a git command. See 'git help'.")
    1
  end

  defp git_usage(ctx) do
    IO.puts(ctx, """
    usage: git [-C <path>] <command> [<args>]

    start a working area      init, clone
    work on the current change add, rm, restore, reset, stash
    examine the history        status, log, show, diff, ls-files, cat-file
    grow and tweak history     branch, checkout, switch, commit, merge (ff), tag
    collaborate (GitHub)       fetch, pull, push, remote, ls-remote
    aliases from ~/.gitconfig  #{ctx |> Ctx.home() |> Config.global() |> Config.section("alias") |> Enum.map_join(" ", &elem(&1, 0))}
    """)

    0
  end

  defp checkout_args(repo, cmd, args, ctx) do
    case args do
      ["--" | paths] ->
        Git.restore(repo, Enum.map(paths, &Ctx.path(ctx, &1)))
        0

      [target] ->
        if File.exists?(Ctx.path(ctx, target)) and not Git.resolve_ref(repo, "refs/heads/" <> target) do
          Git.restore(repo, [Ctx.path(ctx, target)])
          0
        else
          case Git.checkout(repo, target) do
            :ok -> IO.puts(ctx, "Switched to branch '#{target}'"); 0
            {:error, e} -> IO.err(ctx, "error: #{e}"); 1
          end
        end

      _ ->
        IO.err(ctx, "usage: git #{cmd} [-b NEW] BRANCH")
        1
    end
  end

  defp expand_github_shorthand(url) do
    if Regex.match?(~r{^[\w.-]+/[\w.-]+$}, url) and not File.exists?(url), do: "https://github.com/#{url}.git", else: url
  end

  defp config_key(section) do
    case String.split(section, " ", parts: 2) do
      [s, sub] -> s <> "." <> String.trim(sub, "\"")
      [s] -> s
    end
  end

  defp split_key(key) do
    parts = String.split(key, ".")

    case parts do
      [s, k] -> {s, k}
      [s | rest] -> {"#{s} \"#{rest |> Enum.drop(-1) |> Enum.join(".")}\"", List.last(rest)}
    end
  end

  defp short(:modified), do: "M"
  defp short(:deleted), do: "D"
  defp short(:"new file"), do: "A"
  defp short(_), do: "?"

  defp decorations(repo) do
    head = Git.head_sha(repo)
    current = Git.current_branch(repo)

    entries =
      Enum.map(Git.branches(repo), &{Git.resolve_ref(repo, "refs/heads/" <> &1), if(&1 == current, do: "HEAD -> " <> &1, else: &1)}) ++
        Enum.map(Git.remote_branches(repo), &{Git.resolve_ref(repo, "refs/remotes/" <> &1), &1}) ++
        Enum.map(Path.wildcard(Path.join(repo.git_dir, "refs/tags/*")), &{String.trim(File.read!(&1)), "tag: " <> Path.basename(&1)}) ++
        if(current == nil and head, do: [{head, "HEAD"}], else: [])

    Enum.group_by(entries, &elem(&1, 0), &elem(&1, 1))
  end

  defp decoration_text(_ctx, nil, _), do: ""
  defp decoration_text(ctx, names, _), do: " " <> color(ctx, "33", "(") <> color(ctx, "1;36", Enum.join(names, ", ")) <> color(ctx, "33", ")")

  # --pretty=format: placeholders used by the user's `gl`/`gll` aliases.
  defp pretty_format(ctx, fmt, c, decos) do
    now = System.os_time(:second)

    Regex.replace(~r/%(C\([a-z]+\)|Creset|[a-zA-Z]{1,2})/, fmt, fn _, code ->
      case code do
        "H" -> c.sha
        "h" -> String.slice(c.sha, 0, 7)
        "s" -> c.subject
        "b" -> c.message |> String.split("\n", parts: 2) |> Enum.at(1, "") |> String.trim()
        "n" -> "\n"
        "an" -> c.author_name
        "ae" -> c.author_email
        "cn" -> c.author_name
        "ce" -> c.author_email
        "cr" -> relative_time(now - c.time)
        "ar" -> relative_time(now - c.time)
        "ad" -> DateTime.from_unix!(c.time) |> DateTime.to_string()
        "d" -> if decos, do: " (" <> Enum.join(decos, ", ") <> ")", else: ""
        "D" -> if decos, do: Enum.join(decos, ", "), else: ""
        "Creset" -> if Lepton.Style.color?(ctx), do: "\e[0m", else: ""
        "C(" <> name -> if Lepton.Style.color?(ctx), do: "\e[#{color_code(String.trim_trailing(name, ")"))}m", else: ""
        other -> "%" <> other
      end
    end)
  end

  defp color_code("red"), do: "31"
  defp color_code("green"), do: "32"
  defp color_code("yellow"), do: "33"
  defp color_code("blue"), do: "34"
  defp color_code("magenta"), do: "35"
  defp color_code("cyan"), do: "36"
  defp color_code(_), do: "0"

  # A commit's date as git shows it: in the offset it was made in.
  defp git_date(c) do
    tz = Map.get(c, :tz, "+0000")
    <<sign, hh::binary-2, mm::binary-2>> = tz
    off = (String.to_integer(hh) * 3600 + String.to_integer(mm) * 60) * if(sign == ?-, do: -1, else: 1)
    (c.time + off) |> DateTime.from_unix!() |> Lepton.Commands.System.strftime("%a %b %e %H:%M:%S %Y ") |> Kernel.<>(tz)
  end

  defp relative_time(s) when s < 60, do: "#{s} seconds ago"
  defp relative_time(s) when s < 3600, do: "#{div(s, 60)} minutes ago"
  defp relative_time(s) when s < 86_400, do: "#{div(s, 3600)} hours ago"
  defp relative_time(s) when s < 86_400 * 30, do: "#{div(s, 86_400)} days ago"
  defp relative_time(s) when s < 86_400 * 365, do: "#{div(s, 86_400 * 30)} months ago"
  defp relative_time(s), do: "#{div(s, 86_400 * 365)} years ago"

  defp edit_message(ctx, repo) do
    path = Path.join(repo.git_dir, "COMMIT_EDITMSG")
    File.write!(path, "\n# Please enter the commit message for your changes. Lines starting\n# with '#' will be ignored.\n")

    if ctx.tty do
      Lepton.Editor.run([path], ctx)
      path |> File.read!() |> String.split("\n") |> Enum.reject(&String.starts_with?(&1, "#")) |> Enum.join("\n") |> String.trim()
    else
      ""
    end
  end

  # -- claude-code --------------------------------------------------------------------

  defp claude_code([cmd | _], ctx) when cmd in ["install", "update", "remove"] and ctx.user != "root",
    do: Lepton.Users.denied(ctx, "claude-code #{cmd}")

  defp claude_code(args, ctx) when args in [[], ["status"]] do
    alias Lepton.ClaudeCode

    if ClaudeCode.installed?() do
      IO.puts(ctx, "Claude Code #{ClaudeCode.version()} (#{ClaudeCode.platform()}), in #{ClaudeCode.dir()}")
      IO.puts(ctx, "  Run it with: claude. Update it with: sudo claude-code update")
      0
    else
      IO.puts(ctx, "Claude Code isn't installed. Install it with: sudo claude-code install")
      1
    end
  end

  defp claude_code([cmd], ctx) when cmd in ["install", "update"] do
    say = &IO.puts(ctx, String.trim_trailing(&1))
    if cmd == "install", do: say.("Claude Code is Anthropic's, not part of Lepton: this downloads Anthropic's build, and using it is subject to Anthropic's terms.")

    case Lepton.ClaudeCode.install(say) do
      :ok ->
        if cmd == "install", do: say.("Start it with: claude (it asks you to log in the first time).")
        0

      {:error, reason} ->
        IO.err(ctx, "claude-code: #{reason}")
        1
    end
  end

  defp claude_code(["remove"], ctx) do
    Lepton.ClaudeCode.remove()
    IO.puts(ctx, "Removed Claude Code. Your settings and sessions (~/.claude) are kept.")
    0
  end

  defp claude_code(_, ctx) do
    IO.err(ctx, "usage: claude-code [status] | install | update | remove")
    2
  end
end
