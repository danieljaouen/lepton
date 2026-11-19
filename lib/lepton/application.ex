defmodule Lepton.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Lepton.Proc,
      Lepton.Services,
      Lepton.Clipboard,
      Lepton.Net,
      Lepton.USB,
      Lepton.Media,
      Lepton.Sound,
      Lepton.Memory,
      Lepton.Bluetooth,
      Lepton.Wifi,
      Lepton.Users,
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

  # (the texts, newest first, and the processes told of new ones)
  def start_link(_), do: Agent.start_link(fn -> {[], []} end, name: __MODULE__)

  def put(text) do
    if Process.whereis(__MODULE__) do
      watchers = Agent.get_and_update(__MODULE__, fn {texts, ws} -> ws = Enum.filter(ws, &Process.alive?/1); {ws, {Enum.take([text | texts], 50), ws}} end)
      for w <- watchers, do: send(w, {:clipboard, text})
    end

    :ok
  end

  def get do
    if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, fn {texts, _} -> List.first(texts, "") end), else: ""
  end

  def all, do: if(Process.whereis(__MODULE__), do: Agent.get(__MODULE__, &elem(&1, 0)), else: [])

  @doc "Send `pid` `{:clipboard, text}` for each new text (Photon: Wayland programs' clipboard)."
  def watch(pid) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn {texts, ws} -> {texts, Enum.uniq([pid | ws])} end)
    :ok
  end

  @doc "OSC 52: also hand the text to the host terminal's clipboard."
  def osc52(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"
end

defmodule Lepton.Session do
  @moduledoc """
  A login session: a TTY plus a login shell that is respawned when it exits
  (the job `getty` + `login` do on Unix). Once user accounts exist
  (`Lepton.Users`, created by the installer), each console asks for a user
  name and password; until then (the live ISO) it logs `root` in
  automatically.
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
    accounts? = mode == :forever and Lepton.Sys.native?() and Lepton.Users.any?()
    ctx = login_ctx(tty, name)
    ctx = if accounts?, do: login(ctx, name), else: ctx
    # First-run setup (Wi-Fi prompt, post-install tutorial).
    if mode == :forever, do: Lepton.Setup.run(ctx)
    motd(ctx)
    shell = Task.async(fn -> Lepton.Shell.login(ctx) end)
    Task.await(shell, :infinity)

    if mode == :forever do
      # C-d / exit end the login shell. With accounts, the console asks for
      # a login again; without, it logs root straight back in, so point
      # people at the real way to switch off.
      Lepton.IO.write(tty, if(accounts?, do: "\r\nlogout\r\n", else: logout_message()))
      loop(tty, name, mode)
    end
  end

  # getty + login: ask until a user name and password match.
  defp login(ctx, name) do
    Lepton.IO.write(ctx, "\r\nLepton OS #{Lepton.Init.version()} (#{name})\r\n\r\n")
    Lepton.IO.write(ctx, "#{Lepton.Sys.hostname()} login: ")

    user =
      case Lepton.IO.read_line(ctx) do
        line when is_binary(line) -> String.trim(line)
        _ -> ""
      end

    password = if user == "", do: nil, else: Lepton.Setup.read_secret(ctx, "Password: ")

    case user != "" and password != nil and Lepton.Users.verify(user, password) && Lepton.Users.get(user) do
      %Lepton.Users{} = account ->
        Lepton.Users.as(ctx, account, login: true)

      _ ->
        if user != "", do: (Process.sleep(1500); Lepton.IO.write(ctx, "\r\nLogin incorrect\r\n"))
        login(ctx, name)
    end
  end

  @doc false
  def logout_message do
    "\r\nlogout\r\n\r\n" <>
      "  \e[1mLepton logs this console straight back in.\e[0m\r\n" <>
      "  To shut down, type \e[1;36mpoweroff\e[0m (or use UTM's power button -> Request power down).\r\n\r\n"
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
