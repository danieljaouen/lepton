defmodule Lepton.Commands.Services do
  @moduledoc "The service manager (`svc`/`systemctl`, `journalctl`) and `httpd`, a static web server to run under it."

  use Lepton.Command

  alias Lepton.{Ctx, IO, Services, Style}
  alias Lepton.Services.Unit

  @usage """
  svc                              list services
  svc status [NAME...]             state, PID, uptime and recent log lines
  svc start|stop|restart NAME...   control a service
  svc enable|disable [--now] NAME  start at boot (--now: also start/stop it)
  svc logs NAME [-n N] [-f]        its log (-f: follow; C-c to stop)
  svc cat NAME                     show the unit file
  svc new NAME COMMAND...          create ~/.config/lepton/services/NAME.service
  svc edit NAME                    edit (or create) a unit file in le
  svc is-active|is-enabled NAME    for scripts (exit status 0 = yes)\
  """

  defcmd "svc", "start, stop and restart long-running services (like systemctl)",
    usage: "svc [list|status|start|stop|restart|enable|disable|logs|cat|new|edit] ...",
    aliases: ["systemctl"] do
    svc(args, ctx)
  end

  defcmd "journalctl", "show service logs (journalctl -u NAME [-n N] [-f])", usage: "journalctl -u NAME [-n N] [-f]" do
    {opts, _} = Lepton.Args.getopt(args, "u:n:f")

    case opts["u"] do
      nil -> IO.err(ctx, "journalctl: Lepton keeps logs per service: journalctl -u NAME (see: svc)"); 1
      name -> logs(ctx, name, opts)
    end
  end

  defcmd "httpd", "serve a directory over HTTP (static files)", usage: "httpd [-p PORT] [DIR]" do
    {opts, rest} = Lepton.Args.getopt(args, "p:")
    port = Lepton.Args.int(opts, "p", 8080)
    dir = Ctx.path(ctx, List.first(rest, "."))
    httpd(ctx, port, dir)
  end

  defcmd "sshd", "SSH server: log in to Lepton from other machines, with keys only", usage: "sshd [-p PORT]", root: true do
    {opts, _} = Lepton.Args.getopt(args, "p:")
    sshd(ctx, Lepton.Args.int(opts, "p", Lepton.SSHD.default_port()))
  end

  defcmd "crond", "the cron daemon: runs the jobs in the crontabs (the cron service runs it)", usage: "crond", root: true do
    Lepton.Cron.daemon(&IO.puts(ctx, &1))
  end

  defcmd "crontab", "your table of commands to run at set times (cron): list, edit, install or remove it",
    usage: "crontab [-u USER] -l | -e | -r | FILE | -" do
    crontab(args, ctx)
  end

  # -- svc ------------------------------------------------------------------------------------

  # Changing services is for root; looking at them is for everyone.
  @svc_changes ~w(start stop restart reload enable disable new edit)

  defp svc([cmd | _], ctx) when cmd in @svc_changes and ctx.user != "root", do: Lepton.Users.denied(ctx, "svc #{cmd}")

  defp svc(args, ctx) do
    case args do
      [] -> list(ctx)
      [cmd | _] when cmd in ["list", "list-units", "ls"] -> list(ctx)
      ["status"] -> list(ctx)
      ["status" | names] -> each(names, &status(ctx, &1))
      ["start" | names] when names != [] -> each(names, &start(ctx, &1))
      ["stop" | names] when names != [] -> each(names, &stop(ctx, &1))
      [cmd | names] when cmd in ["restart", "reload"] and names != [] -> each(names, &restart(ctx, &1))
      ["enable" | rest] when rest != [] -> enable(ctx, rest, true)
      ["disable" | rest] when rest != [] -> enable(ctx, rest, false)
      ["logs", name | rest] -> logs(ctx, name, elem(Lepton.Args.getopt(rest, "n:f"), 0))
      ["cat", name] -> cat(ctx, name)
      ["new", name | cmd] when cmd != [] -> new(ctx, name, Enum.join(cmd, " "))
      ["edit", name] -> edit(ctx, name)
      ["is-active", name] -> if(Services.status(name).state == :active, do: say(ctx, "active", 0), else: say(ctx, to_string(Services.status(name).state), 3))
      ["is-enabled", name] -> if(Services.enabled?(name), do: say(ctx, "enabled", 0), else: say(ctx, "disabled", 1))
      ["daemon-reload"] -> say(ctx, "Unit files are read at every start; nothing to reload.", 0)
      _ -> IO.puts(ctx, @usage); 2
    end
  end

  defp say(ctx, text, status) do
    IO.puts(ctx, text)
    status
  end

  defp each(names, fun), do: Enum.reduce(names, 0, fn n, status -> max(fun.(String.replace_suffix(n, ".service", "")), status) end)

  defp start(ctx, name) do
    case Services.start(name) do
      {:ok, :already_running} ->
        IO.puts(ctx, "#{name} is already running")
        0

      {:ok, pid} ->
        # Report a service that dies straight away (bad command, port in use).
        Process.sleep(400)

        case Services.status(name) do
          %{state: :active} -> IO.puts(ctx, "#{paint(ctx, "●", "bold green")} started #{name} (PID #{pid})"); 0
          %{state: :activating} = s -> IO.err(ctx, "#{name} #{Services.describe(s.result)}; restarting (svc status #{name})"); 1
          s -> IO.err(ctx, "#{name} #{Services.describe(s.result)}"); print_tail(ctx, s.tail, 5); 1
        end

      {:error, e} ->
        IO.err(ctx, "svc: #{e}")
        1
    end
  end

  defp stop(ctx, name) do
    case Services.stop(name) do
      :ok -> IO.puts(ctx, "stopped #{name}"); 0
      {:ok, :not_running} -> IO.puts(ctx, "#{name} is not running"); 0
      {:error, e} -> IO.err(ctx, "svc: #{e}"); 1
    end
  end

  defp restart(ctx, name) do
    case Services.stop(name) do
      {:error, e} -> IO.err(ctx, "svc: #{e}"); 1
      _ -> start(ctx, name)
    end
  end

  defp enable(ctx, args, on?) do
    {now, names} = Enum.split_with(args, &(&1 == "--now"))

    each(names, fn name ->
      cond do
        on? and Services.unit_path(name) == nil ->
          IO.err(ctx, "svc: no unit file for #{name}")
          1

        true ->
          Services.set_enabled(name, on?)
          IO.puts(ctx, "#{if on?, do: "enabled", else: "disabled"} #{name}" <> if(on?, do: " (starts at boot)", else: ""))
          if now == [], do: 0, else: if(on?, do: start(ctx, name), else: stop(ctx, name))
      end
    end)
  end

  defp list(ctx) do
    case Services.list() do
      {:error, e} ->
        IO.err(ctx, "svc: #{e}")
        1

      [] ->
        IO.puts(ctx, "No services. Create one: svc new NAME COMMAND...")
        0

      services ->
        IO.puts(ctx, paint(ctx, "  SERVICE          STATE        ENABLED   PID    UPTIME    DESCRIPTION", "bold"))

        for s <- services do
          state = String.pad_trailing(state_word(s), 12)
          IO.puts(ctx, "#{dot(ctx, s.state)} #{String.pad_trailing(s.name, 16)} #{paint(ctx, state, state_style(s.state))} #{String.pad_trailing(if(s.enabled, do: "enabled", else: "-"), 9)} #{String.pad_trailing(to_string(s.pid || "-"), 6)} #{String.pad_trailing(if(s.state == :active, do: ago(s.since), else: "-"), 9)} #{s.description || ""}")
        end

        0
    end
  end

  defp status(ctx, name) do
    case Services.status(name) do
      {:error, e} ->
        IO.err(ctx, "svc: #{e}")
        1

      %{unit: {:error, e}, state: :inactive} ->
        IO.err(ctx, "svc: #{e}")
        4

      s ->
        desc = if is_map(s.unit) and s.unit.description, do: " - " <> s.unit.description, else: ""
        IO.puts(ctx, "#{dot(ctx, s.state)} #{paint(ctx, name, "bold")}#{desc}")
        loaded = if is_map(s.unit), do: "#{s.unit.path}; #{if s.enabled, do: "enabled", else: "disabled"}", else: elem(s.unit, 1)
        IO.puts(ctx, "    Loaded: #{loaded}")
        IO.puts(ctx, "    Active: #{paint(ctx, state_word(s), state_style(s.state))}#{since(s)}")
        if s.pid, do: IO.puts(ctx, "       PID: #{s.pid}  (#{s.unit.exec_start})")
        if is_map(s.unit) and s.unit.restart != "no", do: IO.puts(ctx, "   Restart: #{s.unit.restart} after #{s.unit.restart_sec}s (#{s.restarts} so far)")
        if is_map(s.unit) and s.unit.ignored != [], do: IO.puts(ctx, "   Ignored: #{Enum.join(s.unit.ignored, ", ")} (not supported)")
        print_tail(ctx, s.tail, 10)
        if s.state == :active, do: 0, else: 3
    end
  end

  defp print_tail(_ctx, [], _n), do: :ok

  defp print_tail(ctx, lines, n) do
    IO.puts(ctx, "")
    for l <- Enum.take(lines, -n), do: IO.puts(ctx, l)
  end

  defp logs(ctx, name, opts) do
    name = String.replace_suffix(name, ".service", "")
    n = Lepton.Args.int(opts, "n", if(opts["f"], do: 10, else: 50))

    case Services.logs(name, n) do
      [] when not is_map_key(opts, "f") -> IO.puts(ctx, "No log for #{name} yet (#{Services.log_path(name)})")
      lines -> Enum.each(lines, &IO.puts(ctx, &1))
    end

    if opts["f"] do
      :ok = Services.follow(name)
      follow(ctx)
    else
      0
    end
  end

  defp follow(ctx) do
    receive do
      {:svc_log, line} ->
        IO.puts(ctx, line)
        follow(ctx)
    end
  end

  defp cat(ctx, name) do
    case Services.unit_path(name) do
      nil -> IO.err(ctx, "svc: no unit file for #{name}"); 1
      path -> IO.puts(ctx, paint(ctx, "# " <> path, "dimmed")); Elixir.IO.write(ctx.stdout, File.read!(path)); 0
    end
  end

  defp new(ctx, name, command) do
    path = Path.join(Services.user_dir(), name <> ".service")

    cond do
      not Unit.valid_name?(name) ->
        IO.err(ctx, "svc: invalid service name #{inspect(name)}")
        1

      File.exists?(path) ->
        IO.err(ctx, "svc: #{Ctx.tildify(ctx, path)} already exists (svc edit #{name})")
        1

      true ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, template(name, command))
        IO.puts(ctx, "created #{Ctx.tildify(ctx, path)}\nstart it with: svc start #{name}   (svc enable #{name} to start at boot)")
        0
    end
  end

  defp edit(ctx, name) do
    path = Services.unit_path(name) || Path.join(Services.user_dir(), name <> ".service")

    # Shipped units are edited as a user copy that overrides them.
    path =
      if String.starts_with?(path, Services.system_dir()) do
        copy = Path.join(Services.user_dir(), name <> ".service")
        File.mkdir_p!(Path.dirname(copy))
        File.cp!(path, copy)
        copy
      else
        path
      end

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, template(name, "echo replace me with your command"))
    end

    {:ok, le} = Lepton.Commands.lookup("le")
    status = Lepton.Commands.invoke(le, [path], ctx)
    IO.puts(ctx, "Changes apply at the next start: svc restart #{name}")
    status
  end

  defp template(name, command) do
    """
    [Unit]
    Description=#{name}

    [Service]
    ExecStart=#{command}
    # no | on-failure | always
    Restart=on-failure
    RestartSec=2
    """
  end

  defp state_word(%{state: :active}), do: "active"
  defp state_word(%{state: :activating}), do: "restarting"
  defp state_word(%{state: :failed}), do: "failed"
  defp state_word(%{state: :inactive}), do: "inactive"

  defp state_style(:active), do: "bold green"
  defp state_style(:failed), do: "bold red"
  defp state_style(:activating), do: "yellow"
  defp state_style(_), do: "dimmed"

  defp dot(ctx, state), do: paint(ctx, "●", state_style(state))

  defp since(%{since: nil}), do: ""

  defp since(%{state: state, since: {_, {_, {h, m, s}}}} = st) do
    at = Enum.map_join([h, m, s], ":", &String.pad_leading(to_string(&1), 2, "0"))

    case state do
      :active -> " since #{at}; #{ago(st.since)} ago"
      _ -> " since #{at}" <> if(st.result, do: " (#{Services.describe(st.result)})", else: "")
    end
  end

  defp ago(nil), do: "-"

  defp ago({mono, _}) do
    s = div(System.monotonic_time(:millisecond) - mono, 1000)

    cond do
      s < 60 -> "#{s}s"
      s < 3600 -> "#{div(s, 60)}min #{rem(s, 60)}s"
      true -> "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}min"
    end
  end

  defp paint(ctx, text, style), do: Style.apply(text, style, Style.color?(ctx) and Lepton.TTY.tty?(ctx.stdout))

  # -- httpd ----------------------------------------------------------------------------------

  defp httpd(ctx, port, dir) do
    if File.dir?(dir) do
      :inets.start()
      root = String.to_charlist(dir)

      # Static files only: no CGI/ESI modules.
      config = [
        port: port, bind_address: :any, server_name: ~c"lepton", server_root: root, document_root: root,
        directory_index: [~c"index.html", ~c"index.htm"], modules: [:mod_alias, :mod_dir, :mod_get, :mod_head],
        mime_types: [{~c"html", ~c"text/html"}, {~c"htm", ~c"text/html"}, {~c"css", ~c"text/css"}, {~c"js", ~c"text/javascript"},
                     {~c"json", ~c"application/json"}, {~c"txt", ~c"text/plain"}, {~c"md", ~c"text/plain"}, {~c"png", ~c"image/png"},
                     {~c"jpg", ~c"image/jpeg"}, {~c"svg", ~c"image/svg+xml"}, {~c"ico", ~c"image/x-icon"}]
      ]

      # Trap exits so `svc stop` / C-c shut the server down cleanly.
      Process.flag(:trap_exit, true)

      case :inets.start(:httpd, config, :stand_alone) do
        {:ok, server} ->
          IO.puts(ctx, "httpd: serving #{dir} on http://0.0.0.0:#{port}/")
          serve(server)

        {:error, reason} ->
          IO.err(ctx, "httpd: cannot listen on port #{port}: #{inspect(reason)}")
          1
      end
    else
      IO.err(ctx, "httpd: #{dir}: no such directory")
      1
    end
  end

  defp serve(server) do
    receive do
      {:EXIT, ^server, reason} -> exit(reason)
      {:EXIT, _from, reason} -> :inets.stop(:stand_alone, server); exit(reason)
      {:signal, sig} when sig in [:term, :int] -> :inets.stop(:stand_alone, server); 0
      _ -> serve(server)
    end
  end

  # -- sshd -----------------------------------------------------------------------------------

  defp sshd(ctx, port) do
    # Trap exits so `svc stop` / C-c shut the daemon down cleanly.
    Process.flag(:trap_exit, true)

    case Lepton.SSHD.start(port, log: self()) do
      {:ok, daemon} ->
        {:ok, key} = Lepton.SSHD.host_key()
        IO.puts(ctx, "sshd: listening on port #{port}, keys only (no passwords)")
        IO.puts(ctx, "sshd: host key #{Lepton.SSH.fingerprint(Lepton.SSH.public(key))} (ED25519)")

        for {_iface, l} <- Lepton.Net.leases(),
            do: IO.puts(ctx, "sshd: log in with: ssh USER@#{Lepton.Net.format_ip(l.ip)}#{if port != 22, do: " -p #{port}", else: ""}")

        serve_sshd(ctx, daemon)

      {:error, reason} ->
        IO.err(ctx, "sshd: cannot listen on port #{port}: #{inspect(reason)}")
        1
    end
  end

  defp serve_sshd(ctx, daemon) do
    receive do
      {:sshd_log, line} -> IO.puts(ctx, "sshd: " <> line); serve_sshd(ctx, daemon)
      {:EXIT, _from, reason} -> Lepton.SSHD.stop(daemon); exit(reason)
      {:signal, sig} when sig in [:term, :int] -> Lepton.SSHD.stop(daemon); 0
      _ -> serve_sshd(ctx, daemon)
    end
  end

  # -- crontab --------------------------------------------------------------------------------

  @crontab_usage "usage: crontab [-u USER] -l | -e | -r | FILE | -"

  @template """
  # Your crontab: commands to run at set times. Times are UTC (see `date`).
  # Each line: minute hour day-of-month month day-of-week command
  #   *  any     1,15  a list     1-5  a range     */10  every tenth
  # or @reboot, @hourly, @daily, @weekly, @monthly, @yearly, then the command.
  # What a job prints goes to the cron log: svc logs cron
  #
  # m  h  dom mon dow  command
  # */5 *  *   *   *   date >> ~/heartbeat.log
  # 0  3  *   *   1-5  rsync -a ~/notes/ /media/BACKUP/notes/
  """

  defp crontab(args, ctx) do
    {opts, operands} = Lepton.Args.getopt(args, "u:lerih")
    user = opts["u"] || ctx.user

    cond do
      opts["u"] && opts["u"] != ctx.user && not Lepton.Users.root?(ctx) ->
        IO.err(ctx, "crontab: only root may use -u for another user")
        1

      Lepton.Users.get(user) == nil ->
        IO.err(ctx, "crontab: no such user: #{user}")
        1

      opts["l"] ->
        case Lepton.Cron.read(user) do
          nil -> IO.err(ctx, "no crontab for #{user}"); 1
          text -> IO.write(ctx, text); 0
        end

      opts["r"] ->
        case Lepton.Cron.remove(user) do
          :ok -> 0
          _ -> IO.err(ctx, "no crontab for #{user}"); 1
        end

      opts["e"] ->
        edit_crontab(ctx, user)

      match?([_], operands) ->
        text =
          case operands do
            ["-"] -> {:ok, IO.read_all(ctx.stdin)}
            [file] -> File.read(Ctx.path(ctx, file))
          end

        case text do
          {:ok, t} -> install_crontab(ctx, user, t)
          {:error, r} -> IO.err(ctx, "crontab: #{hd(operands)}: #{:file.format_error(r)}"); 1
        end

      true ->
        IO.err(ctx, @crontab_usage)
        1
    end
  end

  defp install_crontab(ctx, user, text) do
    case Lepton.Cron.install(user, text) do
      :ok ->
        0

      {:error, errors} ->
        for {n, msg} <- errors, do: IO.err(ctx, "crontab: line #{n}: #{msg}")
        IO.err(ctx, "crontab: errors in crontab file, can't install")
        1
    end
  end

  # Edit a copy; install it if it changed and parses, else offer to edit again.
  defp edit_crontab(ctx, user) do
    if ctx.tty == nil do
      IO.err(ctx, "crontab: -e needs a terminal; use crontab FILE")
      1
    else
      old = Lepton.Cron.read(user)
      tmp = Path.join(System.tmp_dir() || "/tmp", "crontab.#{user}.#{System.unique_integer([:positive])}")
      File.write!(tmp, old || @template)

      try do
        edit_loop(ctx, user, tmp, old || @template)
      after
        File.rm(tmp)
      end
    end
  end

  defp edit_loop(ctx, user, tmp, before) do
    Lepton.Editor.run([tmp], ctx)
    text = File.read!(tmp)

    cond do
      text == before ->
        IO.puts(ctx, "crontab: no changes made to crontab")
        0

      true ->
        case Lepton.Cron.install(user, text) do
          :ok ->
            IO.puts(ctx, "crontab: installing new crontab")
            0

          {:error, errors} ->
            for {n, msg} <- errors, do: IO.err(ctx, "crontab: line #{n}: #{msg}")
            IO.write(ctx, "Errors in crontab file. Edit again? (y/n) ")

            case IO.read_line(ctx.stdin) do
              line when is_binary(line) ->
                if String.trim(line) in ["y", "Y", "yes"], do: edit_loop(ctx, user, tmp, before), else: (IO.puts(ctx, "crontab: edits left in #{tmp} were not installed"); 1)

              _ ->
                1
            end
        end
    end
  end
end
