defmodule Lepton.ClaudeCode do
  @moduledoc """
  Claude Code, Anthropic's coding agent, on Lepton.

  Claude Code isn't open source, so it isn't part of Lepton: `sudo
  claude-code install` downloads Anthropic's own build for Linux on arm64
  with musl (`linux-arm64-musl`) from Anthropic's download server, as
  Anthropic's installer does, and checks it against the release's
  SHA-256 checksum. Using it is subject to Anthropic's terms.

  It needs what it finds on any Linux system, so the `claude-code` app
  brings those from Alpine:

  - bash, the shell its Bash tool runs commands in;
  - ripgrep, for searching files; git;
  - util-linux's `script`, which gives it a terminal.

  The binary is kept in `/var/lib/lepton/claude-code`, outside the app's
  directory, so an update of the Alpine packages leaves it alone.

  **A terminal.** Native programs on Lepton run on pipes: Lepton's
  terminals are Lepton's own (`Lepton.TTY`), not the kernel's. Claude
  Code's interface needs a real one, so it runs under `script`, which
  opens a pseudo-terminal, runs it there, and relays it over pipes. Keys
  read from Lepton's terminal in raw mode go to it as bytes, its output
  goes to the terminal, and a resize of the window sets the
  pseudo-terminal's size (`stty -F`) and sends SIGWINCH.

  **Commands it runs.** The Bash tool runs in Alpine's bash with Alpine's
  programs, busybox's for the rest, and `mix` and `elixir` running the
  image's Erlang and Elixir in a VM of their own (as `Lepton.MixVM`).
  Lepton's own commands are Lepton's: they run in Lepton's VM, which a
  native program can't reach.
  """

  alias Lepton.{Alpine, Apps, IO, Keys, TTY}

  @app "claude-code"
  @base "https://downloads.claude.ai/claude-code-releases"
  @platform "linux-arm64-musl"

  def app, do: @app
  def platform, do: @platform
  def dir, do: Path.join(Lepton.Persist.state_dir(), "claude-code")
  def binary, do: Path.join(dir(), "claude")

  @doc "The installed Claude Code version, or nil."
  def version do
    case File.read(Path.join(dir(), "version")) do
      {:ok, v} -> String.trim(v)
      _ -> nil
    end
  end

  def installed?, do: Apps.installed?(@app) and File.exists?(binary()) and version() != nil

  # -- installing ---------------------------------------------------------------------

  @doc """
  Install Claude Code, or update it to the latest release: the Alpine
  programs it needs, then Anthropic's binary. `say` reports progress.
  """
  def install(say \\ fn _ -> :ok end) do
    tools = if Apps.installed?(@app), do: :ok, else: (say.("Installing the programs Claude Code needs (bash, git, ripgrep)..."); Apps.install(@app, say))

    with :ok <- tools,
         {:ok, latest} <- latest() do
      if latest == version() and File.exists?(binary()) do
        say.("Claude Code #{latest} is the latest; nothing to do.")
        :ok
      else
        download(latest, say)
      end
    end
  end

  @doc "The latest release's version."
  def latest do
    case Alpine.get(@base <> "/latest") do
      {:ok, body} ->
        v = String.trim(body)
        if v =~ ~r/^\d+\.\d+\.\d+/, do: {:ok, v}, else: {:error, "the download server didn't answer with a version"}

      {:error, reason} ->
        {:error, "can't reach downloads.claude.ai: #{inspect(reason)}"}
    end
  end

  @doc "This platform's checksum and size in a release manifest (JSON text)."
  def manifest_entry(json) do
    with {:ok, %{"platforms" => %{@platform => %{"checksum" => sum, "size" => size}}}} <- JSON.decode(json),
         true <- is_binary(sum) and sum =~ ~r/^[0-9a-f]{64}$/ and is_integer(size) do
      {:ok, sum, size}
    else
      _ -> {:error, "the release has no #{@platform} build"}
    end
  end

  defp download(v, say) do
    File.mkdir_p!(dir())
    part = binary() <> ".part"

    with {:ok, json} <- Alpine.get("#{@base}/#{v}/manifest.json") |> describe("the release's manifest"),
         {:ok, sum, size} <- manifest_entry(json),
         _ = say.("Downloading Claude Code #{v} (#{div(size, 1_000_000)} MB)..."),
         :ok <- Alpine.download("#{@base}/#{v}/#{@platform}/claude", part, progress(size, say)) |> describe("the download"),
         :ok <- verify(part, sum, size) do
      File.chmod!(part, 0o755)
      File.rename!(part, binary())
      File.write!(Path.join(dir(), "version"), v <> "\n")
      say.("Claude Code #{v} is installed.")
      :ok
    else
      error ->
        File.rm(part)
        error
    end
  end

  defp describe(:ok, _), do: :ok
  defp describe({:ok, _} = ok, _), do: ok
  defp describe({:error, reason}, what), do: {:error, "#{what} failed: #{inspect(reason)}"}

  # Every 10%.
  defp progress(size, say) do
    fn n ->
      step = div(n * 10, max(size, 1))
      if step > (Process.get(:claude_code_step) || 0), do: (Process.put(:claude_code_step, step); say.("  #{step * 10}%"))
    end
  end

  @doc "Does the file at `path` have this size and SHA-256 checksum?"
  def verify(path, sum, size) do
    actual =
      File.stream!(path, 1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    cond do
      File.stat!(path).size != size -> {:error, "the download is incomplete"}
      actual != sum -> {:error, "the download doesn't match its checksum"}
      true -> :ok
    end
  end

  def remove do
    File.rm_rf(dir())
    if Apps.installed?(@app), do: Apps.remove(@app), else: :ok
  end

  # -- running --------------------------------------------------------------------------

  @doc "The environment Claude Code runs with, for a user's `env`."
  def env(env, prefix \\ Apps.dir(@app)) do
    qemu = if dir = Lepton.VM.tool_path(), do: [dir], else: []
    path = Enum.join([bin_dir(), Path.join(prefix, "usr/bin"), Path.join(prefix, "bin")] ++ qemu ++ ["/usr/local/bin", "/usr/bin", "/bin", applets_dir()], ":")
    certs = Path.join(prefix, "etc/ssl/certs/ca-certificates.crt")

    env
    # (the image's Erlang is built for glibc: musl's libraries go through musl's own path)
    |> Map.delete("LD_LIBRARY_PATH")
    |> Map.merge(%{
      "PATH" => path,
      "SHELL" => Path.join(prefix, "bin/bash"),
      "LANG" => env["LANG"] || "C.UTF-8",
      "USE_BUILTIN_RIPGREP" => "0",
      "DISABLE_AUTOUPDATER" => "1",
      "GIT_EXEC_PATH" => Path.join(prefix, "usr/libexec/git-core"),
      "GIT_TEMPLATE_DIR" => Path.join(prefix, "usr/share/git-core/templates"),
      "GIT_SSL_CAINFO" => certs,
      "SSL_CERT_FILE" => certs
    })
  end

  # Programs made for it at each start: mix and elixir (the image's, in a VM
  # of their own), and busybox's applets for whatever Alpine's packages lack.
  defp bin_dir, do: "/run/lepton/claude-code/bin"
  defp applets_dir, do: "/run/lepton/claude-code/busybox"

  @doc "Write the `mix` and `elixir` scripts into `dir`."
  def write_wrappers(dir) do
    File.mkdir_p!(dir)

    with {erlexec, argv, venv} <- Lepton.MixVM.command([]) do
      # argv: the VM's flags, then -extra -e "Mix.CLI.main()" --.
      {flags, _} = Enum.split_while(argv, &(&1 != "-extra"))
      exports = Enum.map_join(Enum.sort(venv), "", fn {k, v} -> "export #{k}=#{sh_quote(v)}\n" end)
      run = Enum.map_join([erlexec | flags], " ", &sh_quote/1)

      for {name, extra} <- [{"mix", ~s(-extra -e "Mix.CLI.main\(\)" --)}, {"elixir", "-extra"}] do
        file = Path.join(dir, name)
        File.write!(file, "#!/bin/sh\n# Lepton: the image's Elixir, in a VM of its own.\n#{exports}exec #{run} #{extra} \"$@\"\n")
        File.chmod!(file, 0o755)
      end
    end

    :ok
  end

  defp prepare do
    Apps.musl_path(Apps.dir(@app))
    write_wrappers(bin_dir())

    unless File.dir?(applets_dir()) do
      File.mkdir_p!(applets_dir())

      for applet <- busybox_applets(), applet not in ["sh", "env"] do
        File.ln_s("/bin/busybox", Path.join(applets_dir(), applet))
      end
    end

    :ok
  end

  defp busybox_applets do
    case System.cmd("/bin/busybox", ["--list"], stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n", trim: true)
      _ -> []
    end
  end

  @doc "Run `claude` with `args` for `ctx`; returns its exit status."
  def run(args, ctx) do
    cond do
      not installed?() ->
        IO.err(ctx, "claude: Claude Code isn't installed. Install it with: sudo claude-code install")
        1

      args in [["update"], ["upgrade"], ["install"]] ->
        IO.err(ctx, "claude: on Lepton, update it with: sudo claude-code update")
        1

      true ->
        prepare()
        user = Lepton.Users.get(ctx.user) || Lepton.Users.get("root")
        env = env(Map.put(ctx.env, "HOME", ctx.env["HOME"] || user.home))

        if ctx.tty && TTY.tty?(ctx.stdin) && TTY.tty?(ctx.stdout),
          do: interactive(args, ctx, user, env),
          else: batch(args, ctx, user, env)
    end
  end

  # On a pipe (`claude -p`, `echo ... | claude -p`): input from a file
  # (a port can't close its program's input on its own), output to ctx.
  defp batch(args, ctx, user, env) do
    {input, tmp} =
      if ctx.stdin != nil and not TTY.tty?(ctx.stdin) do
        tmp = Path.join(System.tmp_dir!(), "claude-#{System.unique_integer([:positive])}.in")
        File.write!(tmp, IO.read_all(ctx.stdin))
        File.chmod(tmp, 0o644)
        {tmp, tmp}
      else
        {"/dev/null", nil}
      end

    try do
      cmd = "exec #{Enum.map_join([binary() | args], " ", &sh_quote/1)} < #{sh_quote(input)}"
      port = open(user, "/bin/sh", ["-c", cmd], ctx, env)
      drain(port, ctx)
    after
      if tmp, do: File.rm(tmp)
    end
  end

  defp drain(port, ctx) do
    receive do
      {^port, {:data, d}} -> IO.write(ctx, d); drain(port, ctx)
      {^port, {:exit_status, s}} -> s
    end
  end

  defp open(user, exe, argv, ctx, env) do
    {exe, argv} = Lepton.RunAs.command(user, exe, argv)
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: ctx.cwd, env: charlists(env)])
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Lepton.MixVM.guard(os_pid, self())
    port
  end

  @doc "The `script` command line that runs Claude Code on a terminal of `rows` by `cols`."
  def script_argv(args, {rows, cols}) do
    cmd = "/bin/busybox stty rows #{rows} cols #{cols} 2>/dev/null; exec #{Enum.map_join([binary() | args], " ", &sh_quote/1)}"
    ["--quiet", "--return", "--flush", "--command", cmd, "/dev/null"]
  end

  defp interactive(args, ctx, user, env) do
    tty = ctx.tty
    size = TTY.size(tty)
    env = Map.merge(env, %{"TERM" => TTY.term(tty) || "xterm-256color", "COLORTERM" => "truecolor"})
    script = Path.join(Apps.dir(@app), "usr/bin/script")
    TTY.set_mode(tty, :raw)
    me = self()
    reader = spawn_link(fn -> read_keys(tty, me) end)

    try do
      port = open(user, script, script_argv(args, size), ctx, env)
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      relay(port, tty, os_pid)
    after
      send(reader, :stop)
      # Whatever state it left the terminal in: cursor shown, no bracketed paste, no mouse.
      TTY.write(tty, "\e[?25h\e[?2004l\e[?1000l\e[?1006l\e[0m")
      TTY.set_mode(tty, :cooked)
    end
  end

  defp read_keys(tty, owner) do
    receive do
      :stop -> :ok
    after
      0 ->
        case TTY.read_key(tty, 200) do
          :timeout -> :ok
          key -> send(owner, {:claude_key, key})
        end

        read_keys(tty, owner)
    end
  end

  defp relay(port, tty, os_pid) do
    receive do
      {^port, {:data, d}} ->
        TTY.write(tty, d)
        relay(port, tty, os_pid)

      {^port, {:exit_status, s}} ->
        s

      {:claude_key, {:resize, rows, cols}} ->
        resize(os_pid, rows, cols)
        relay(port, tty, os_pid)

      {:claude_key, {:cpr, _, _}} ->
        relay(port, tty, os_pid)

      {:claude_key, key} when is_binary(key) ->
        Port.command(port, Keys.encode(key))
        relay(port, tty, os_pid)

      {:claude_key, _} ->
        relay(port, tty, os_pid)
    end
  end

  # The program under `script` (RunAs's runas execs script, script starts
  # the shell that execs claude): set its terminal's size, then SIGWINCH.
  defp resize(script_pid, rows, cols) do
    with [child | _] <- children(script_pid) do
      Lepton.Sys.shim("stty", ["-F", "/proc/#{child}/fd/0", "rows", to_string(rows), "cols", to_string(cols)])
      Lepton.Sys.shim("kill", ["-WINCH", to_string(child)])
    end
  end

  @doc "The processes whose parent is `pid`."
  def children(pid, proc \\ "/proc") do
    for entry <- File.ls!(proc), entry =~ ~r/^\d+$/, ppid(Path.join([proc, entry, "stat"])) == pid, do: String.to_integer(entry)
  rescue
    _ -> []
  end

  defp ppid(stat_file) do
    # "PID (NAME) STATE PPID ...": the name may hold ") ", so the last one ends it.
    with {:ok, stat} <- File.read(stat_file),
         [_ | _] = parts <- :binary.matches(stat, ") "),
         {at, _} = List.last(parts),
         [_state, ppid | _] <- String.split(binary_part(stat, at + 2, byte_size(stat) - at - 2), " ") do
      String.to_integer(ppid)
    else
      _ -> nil
    end
  end

  @doc "Quote `s` for /bin/sh."
  def sh_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  defp charlists(env), do: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
end
