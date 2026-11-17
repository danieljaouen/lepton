defmodule Lepton.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Lepton.Proc,
      Lepton.Clipboard,
      Lepton.Net,
      {Registry, keys: :unique, name: Lepton.Mux.Registry},
      {DynamicSupervisor, name: Lepton.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Lepton.Supervisor)
  end
end

defmodule Lepton.Clipboard do
  @moduledoc """
  The system clipboard / tmux paste buffer stack (`pbcopy`, `pbpaste`,
  `xclip`, multiplexer copy mode and editor yanks all share it).
  """
  use Agent

  def start_link(_), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def put(text) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &Enum.take([text | &1], 50))
    :ok
  end

  def get do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, &List.first(&1, "")), else: ""
  end

  def all, do: if(Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1), else: [])

  @doc "OSC 52: also hand the text to the host terminal's clipboard."
  def osc52(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"
end

defmodule Lepton.Session do
  @moduledoc """
  A login session: a TTY plus a login shell that is respawned when it exits
  (the job `getty` + `login` do on Unix). Lepton auto-logs-in `root`.
  """

  alias Lepton.{Ctx, TTY}

  def start_console(device) do
    term = if device =~ ~r/tty\d/, do: "linux", else: "xterm-256color"
    spawn(fn ->
      try do
        run(device, {Lepton.TTY.Device, device}, term)
      catch
        kind, reason ->
          Lepton.Init.say("session #{device} crashed: " <> Exception.format(kind, reason, __STACKTRACE__))
      end
    end)
  end

  def start_hosted do
    run("stdio", {Lepton.TTY.Stdio, nil}, System.get_env("TERM", "xterm-256color"), :once)
  end

  def run(name, backend, term, mode \\ :forever) do
    {:ok, tty} = TTY.start_link(backend: backend, name: name, term: term)

    # Serial lines don't know their size; ask the terminal emulator.
    if term != "linux" and TTY.size(tty) == {24, 80} do
      TTY.probe_size(tty)
    end

    loop(tty, name, mode)
  end

  defp loop(tty, name, mode) do
    ctx = login_ctx(tty, name)
    motd(ctx)
    shell = Task.async(fn -> Lepton.Shell.login(ctx) end)
    Task.await(shell, :infinity)

    if mode == :forever do
      Lepton.IO.write(tty, "\r\nlogout\r\n\r\n")
      loop(tty, name, mode)
    end
  end

  def login_ctx(tty, name) do
    {rows, cols} = TTY.size(tty)

    env = %{
      "HOME" => "/root",
      "USER" => "root",
      "LOGNAME" => "root",
      "SHELL" => "/bin/lsh",
      "PATH" => "/usr/local/bin:/usr/bin:/bin",
      "TERM" => TTY.term(tty),
      "LANG" => "C.UTF-8",
      "HOSTNAME" => Lepton.Sys.hostname(),
      "TTY" => name,
      "COLUMNS" => to_string(cols),
      "LINES" => to_string(rows),
      "EDITOR" => "le",
      "VISUAL" => "le",
      "PAGER" => "less"
    }

    home = if Lepton.Sys.native?(), do: "/root", else: System.user_home() || File.cwd!()
    %Ctx{cwd: home, env: Map.put(env, "HOME", home), stdin: tty, stdout: tty, stderr: tty, tty: tty}
  end

  defp motd(ctx) do
    case File.read("/etc/motd") do
      {:ok, text} -> Lepton.IO.write(ctx, text)
      _ -> :ok
    end
  end
end
