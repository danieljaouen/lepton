defmodule Lepton.MixVM do
  @moduledoc """
  `mix` in an Erlang virtual machine of its own, as on any other system.

  Lepton's `elixir` and `iex` evaluate code in Lepton's own VM, which is
  the OS. Mix can't share it: a project's configuration would become the
  OS's, its dependencies would load into the OS, and `mix phx.server`
  would run a web app inside the OS for as long as it serves. So `mix`
  starts the Erlang runtime the image boots from (`erlexec` with the
  `start_clean` boot script, under `/usr/lib/erlang`) as a separate
  program, running `Mix.CLI.main/0`, with the Elixir and Mix of the
  image: `mix.exs`, Hex and archives (`mix local.hex`, `mix archive.install
  hex phx_new`) work as usual, in `~/.mix` and `~/.hex`.

  It runs as you (not root, through `Lepton.RunAs`), so the files it
  writes are yours. When it stops at a question (Mix's `[Yn]`), the line
  typed next is its answer. When its Lepton process ends any way at all (`C-c`, `kill`,
  `svc stop`), the VM gets SIGTERM, a graceful stop (`init:stop/0`), and
  SIGKILL 10 seconds later if it is still there.
  """

  alias Lepton.IO

  @root "/usr/lib/erlang"
  @tools "mix-tools"

  @doc "The program and arguments that run `mix` with `args`: `{exe, argv, env}`, or nil."
  def command(args) do
    if Lepton.Sys.native?() do
      with [erlexec | _] <- Path.wildcard(Path.join(@root, "erts-*/bin/erlexec")) do
        argv = ["+Bd", "+fnu", "-noshell", "-boot", Path.join(@root, "bin/start_clean"), "-s", "elixir", "start_cli", "-extra", "-e", "Mix.CLI.main()", "--" | args]
        env = %{"BINDIR" => Path.dirname(erlexec), "ROOTDIR" => @root, "EMU" => "beam", "PROGNAME" => "erl"}
        {erlexec, argv, env}
      else
        _ -> nil
      end
    else
      # On a development Mac: the host's Mix.
      with exe when exe != nil <- System.find_executable("mix"),
           do: {exe, args, %{"PATH" => Path.dirname(exe) <> ":" <> System.get_env("PATH", "/usr/bin:/bin")}}
    end
  end

  @doc "Run `mix` with `args` for `ctx` (in `ctx.cwd`); returns its exit status."
  def run(args, ctx) do
    case command(args) do
      nil ->
        IO.err(ctx, "mix: no Erlang runtime to run it with")
        1

      {exe, argv, extra} ->
        user = Lepton.Users.get(ctx.user) || Lepton.Users.get("root")
        {exe, argv} = Lepton.RunAs.command(user, exe, argv)

        env =
          ctx.env
          |> Map.merge(extra)
          |> Map.put_new("LANG", "C.UTF-8")
          |> Map.put("HOME", ctx.env["HOME"] || user.home)
          |> then(&Map.put(&1, "PATH", with_qemu(&1["PATH"] || "/usr/local/bin:/usr/bin:/bin")))
          |> then(&Map.merge(&1, git_env(&1["PATH"])))

        port =
          Port.open({:spawn_executable, exe}, [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: argv, cd: ctx.cwd, env: charlists(env)])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        guard(os_pid, self())
        relay(port, ctx, %{tail: "", gen: 0, reading: nil, no_git: false})
    end
  end

  @doc """
  The programs Mix runs, when the `mix-tools` app is installed: Alpine's
  git and inotifywait on PATH (their libraries on musl's search path:
  `LD_LIBRARY_PATH` would reach the VM itself, which is built against
  glibc).
  """
  def git_env(path) do
    prefix = Lepton.Apps.dir(@tools)

    if Lepton.Apps.installed?(@tools) do
      if Lepton.Sys.native?(), do: Lepton.Apps.musl_path(prefix)

      %{
        "PATH" => Path.join(prefix, "usr/bin") <> ":" <> Path.join(prefix, "bin") <> ":" <> path,
        "GIT_EXEC_PATH" => Path.join(prefix, "usr/libexec/git-core"),
        "GIT_TEMPLATE_DIR" => Path.join(prefix, "usr/share/git-core/templates"),
        "GIT_CONFIG_NOSYSTEM" => "1"
      }
    else
      %{}
    end
  end

  # QEMU (the qemu app) on PATH, for `mix lepton.qemu` in a checkout of Lepton.
  defp with_qemu(path) do
    case Lepton.VM.tool_path() do
      nil -> path
      dir -> dir <> ":" <> path
    end
  end

  # Output goes to the terminal. Input is read only when Mix asks for it
  # (its output stops at a question: "Shall I install Hex? [Yn] "), one
  # line, as a program reading its terminal would: what is typed ahead
  # stays the shell's.
  defp relay(port, ctx, st) do
    receive do
      {^port, {:data, d}} ->
        IO.write(ctx, d)
        st = if String.contains?(d, [~s(the "git" executable is not available), "`inotify-tools` is needed"]), do: %{st | no_git: true}, else: st
        tail = (st.tail <> d) |> String.split("\n") |> List.last()
        gen = st.gen + 1
        if ctx.stdin && st.reading == nil && prompt?(tail), do: Process.send_after(self(), {:mix_prompt, gen}, 300)
        relay(port, ctx, %{st | tail: tail, gen: gen})

      {^port, {:exit_status, s}} ->
        if st.reading, do: Process.exit(st.reading, :kill)
        if st.no_git, do: IO.err(ctx, "mix: for git dependencies and Phoenix's live reload: sudo app install mix-tools")
        s

      # Still at the question: read the answer.
      {:mix_prompt, gen} when gen == st.gen and st.reading == nil ->
        me = self()
        reader = spawn(fn -> send(me, {:mix_stdin, IO.read_line(ctx.stdin)}) end)
        relay(port, ctx, %{st | reading: reader})

      {:mix_prompt, _} ->
        relay(port, ctx, st)

      {:mix_stdin, line} ->
        if is_binary(line), do: Port.command(port, line)
        relay(port, ctx, %{st | reading: nil, tail: ""})
    end
  end

  @doc false
  # Does output that stops here ask a question?
  def prompt?(tail), do: Regex.match?(~r/(\[[Yy]n\]|\[y[Nn]\]|\?|:)\s*$/, tail)

  @doc """
  Stop OS process `os_pid` when Lepton process `owner` ends, however it
  ends: SIGTERM, then SIGKILL after `grace` ms. Nothing if it has exited.
  """
  def guard(os_pid, owner, grace \\ 10_000) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:DOWN, ^ref, _, _, _} ->
          if alive?(os_pid) do
            Lepton.Sys.shim("kill", ["-TERM", to_string(os_pid)])
            Enum.find(1..div(grace, 100), fn _ -> not alive?(os_pid) || (Process.sleep(100) && false) end)
            if alive?(os_pid), do: Lepton.Sys.shim("kill", ["-KILL", to_string(os_pid)])
          end
      end
    end)
  end

  # Running, and not a zombie (its parent, the port's helper, reaps it).
  defp alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} -> not String.contains?(stat, ") Z ")
      _ -> false
    end
  end

  defp charlists(env), do: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
end
