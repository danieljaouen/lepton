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

  defcmd "httpd", "web server: files, and HTTPS in front of web apps (Phoenix), WebSockets too",
    usage: "httpd [-p PORT] [-s TLS_PORT] [-x APP_URL] [-c CERT -k KEY] [-r] [-f CONFIG] [DIR]" do
    {opts, rest} = Lepton.Args.getopt(args, "p:s:x:c:k:rf:")
    httpd(ctx, opts, rest)
  end

  defcmd "cert", "TLS certificates for httpd: a local CA, self-signed, Let's Encrypt",
    usage: "cert list | local HOST... | self-signed HOST... | letsencrypt [-m EMAIL] [--staging] DOMAIN... | renew | import NAME CERT KEY | rm NAME | ca | trust" do
    cert(args, ctx)
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

  defp httpd(ctx, opts, rest) do
    log = &IO.puts(ctx, &1)

    base =
      case opts["f"] do
        nil -> {:ok, %Lepton.HTTPD{}}
        path -> Lepton.HTTPD.config(Ctx.path(ctx, path))
      end

    with {:ok, cfg} <- base,
         {:ok, cfg} <- httpd_flags(ctx, cfg, opts, rest) do
      Lepton.HTTPD.run(%{cfg | log: log})
    else
      {:error, msg} when is_binary(msg) -> IO.err(ctx, "httpd: #{msg}"); 1
      {:error, r} -> IO.err(ctx, "httpd: #{opts["f"]}: #{:file.format_error(r)}"); 1
    end
  end

  # The command line's site (a directory or an app), on top of the config file's.
  defp httpd_flags(ctx, cfg, opts, rest) do
    cfg = %{cfg | port: Lepton.Args.int(opts, "p", cfg.port), redirect_https: cfg.redirect_https || opts["r"] == true}
    cfg = if opts["s"], do: %{cfg | tls_port: Lepton.Args.int(opts, "s", 8443)}, else: cfg
    cfg = %{cfg | cert: opts["c"] && Ctx.path(ctx, opts["c"]), key: opts["k"] && Ctx.path(ctx, opts["k"])}

    site =
      cond do
        opts["x"] -> %{host: "*", proxy: opts["x"], root: nil, cert: nil, key: nil}
        rest != [] or cfg.sites == [] -> %{host: "*", root: Ctx.path(ctx, List.first(rest, ".")), proxy: nil, cert: nil, key: nil}
        true -> nil
      end

    cond do
      site && site.root && not File.dir?(site.root) -> {:error, "#{site.root}: no such directory"}
      site && site.proxy && URI.parse(site.proxy).scheme != "http" -> {:error, "#{site.proxy}: the app's address is http://HOST:PORT"}
      (cfg.cert == nil) != (cfg.key == nil) -> {:error, "-c CERT and -k KEY go together"}
      true -> {:ok, %{cfg | sites: cfg.sites ++ List.wrap(site)}}
    end
  end

  # -- cert -----------------------------------------------------------------------------------

  @cert_changes ~w(local self-signed letsencrypt renew import rm trust)

  defp cert([sub | _], ctx) when sub in @cert_changes and ctx.user != "root", do: Lepton.Users.denied(ctx, "cert #{sub}")

  defp cert(args, ctx) do
    case args do
      [] -> cert_list(ctx)
      ["list"] -> cert_list(ctx)
      ["local" | hosts] when hosts != [] -> cert_made(ctx, Lepton.Certs.local(hosts), "from Lepton's local CA")
      ["self-signed" | hosts] when hosts != [] -> cert_made(ctx, Lepton.Certs.self_signed(hosts), "self-signed")
      ["letsencrypt" | rest] -> cert_acme(ctx, rest)
      ["renew" | _] -> cert_renew(ctx)
      ["import", name, c, k] -> cert_done(ctx, Lepton.Certs.import(name, Ctx.path(ctx, c), Ctx.path(ctx, k)), "#{name} imported")
      ["rm", name] -> cert_done(ctx, Lepton.Certs.remove(name), nil)
      ["ca"] -> Lepton.Certs.ca(); IO.write(ctx, File.read!(Lepton.Certs.ca_cert_path())); 0
      ["trust"] -> Lepton.Certs.ca(); Lepton.Certs.trust_local_ca(); IO.puts(ctx, "Lepton's local CA is trusted (Firefox: after a restart)."); 0
      _ -> IO.err(ctx, "usage: cert list | local HOST... | self-signed HOST... | letsencrypt [-m EMAIL] [--staging] DOMAIN... | renew | import NAME CERT KEY | rm NAME | ca | trust"); 2
    end
  end

  defp cert_list(ctx) do
    now = System.os_time(:second)

    for c <- Lepton.Certs.list() do
      days = div(c.not_after - now, 86_400)
      left = if days < 0, do: "EXPIRED", else: "#{days} days"
      IO.puts(ctx, "#{String.pad_trailing(c.name, 24)} #{String.pad_trailing(left, 10)} #{Enum.join(c.hosts, " ")}  (#{c.issuer})")
    end

    0
  end

  defp cert_made(ctx, {:ok, name}, how) do
    IO.puts(ctx, "#{Path.join(Lepton.Certs.dir(), name)}.crt (#{how}); httpd uses it for its names.")
    0
  end

  defp cert_done(ctx, :ok, msg) do
    if msg, do: IO.puts(ctx, msg)
    0
  end

  defp cert_done(ctx, {:error, msg}, _), do: (IO.err(ctx, "cert: #{msg}"); 1)

  defp cert_acme(ctx, args) do
    {opts, domains} = Lepton.Args.getopt(args, "m:")

    if domains == [] do
      IO.err(ctx, "usage: cert letsencrypt [-m EMAIL] [--staging] DOMAIN...")
      2
    else
      dir = if opts["staging"], do: Lepton.Certs.acme_directory(:staging), else: opts["directory"] || Lepton.Certs.acme_directory(:production)

      case Lepton.Certs.acme(domains, email: opts["m"], directory: dir, log: &IO.puts(ctx, "cert: " <> &1)) do
        {:ok, name} -> cert_made(ctx, {:ok, name}, "from Let's Encrypt")
        {:error, msg} -> IO.err(ctx, "cert: #{msg}"); 1
      end
    end
  end

  defp cert_renew(ctx) do
    Enum.reduce(Lepton.Certs.renew(), 0, fn
      {name, {:ok, _}}, st -> IO.puts(ctx, "#{name}: renewed"); st
      {name, {:error, msg}}, _ -> IO.err(ctx, "cert: #{name}: #{msg}"); 1
    end)
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
  # Your crontab: commands to run at set times, in local time (see `date`).
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
