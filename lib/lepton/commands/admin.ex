defmodule Lepton.Commands.Admin do
  @moduledoc "Installation, setup, packages and credits."

  use Lepton.Command

  defcmd "lepton-install", "install Lepton from the ISO onto a disk, or upgrade it there (keeping your files)", usage: "lepton-install [-y] [--upgrade | --erase] [--iso FILE] [-u NAME --password-stdin] [/dev/DISK | /dev/PARTITION]", root: true do
    Lepton.Installer.run(args, ctx)
  end

  defcmd "lepton-tutorial", "an interactive tour of Lepton", usage: "lepton-tutorial", aliases: ["tutorial"] do
    Lepton.Tutorial.run(ctx)
  end

  defcmd "lpm", "Lepton package manager (packages from hex.pm)", usage: "lpm search|info|install|list|remove|update|official|upgrade|revert ..." do
    Lepton.Pkg.cli(args, ctx)
  end

  defcmd "wifi", "Wi-Fi: status, scan, connect and saved networks",
    usage: "wifi [status] | scan [IFACE] | connect SSID [PASSPHRASE] | forget [SSID] | setup" do
    wifi(args, ctx)
  end

  defp wifi(["scan" | rest], ctx) do
    case List.first(rest) || List.first(Lepton.Wifi.wireless_interfaces()) do
      nil ->
        IO.err(ctx, "wifi: no Wi-Fi hardware (UTM/QEMU have none; pass a USB Wi-Fi adapter through to the VM)")
        1

      iface ->
        IO.puts(ctx, "Scanning on #{iface}...")

        case Lepton.Wifi.scan(iface) do
          {:ok, []} ->
            IO.puts(ctx, "No networks found.")
            0

          {:ok, nets} ->
            IO.puts(ctx, String.pad_trailing("SSID", 32) <> " SIGNAL    SECURITY   BAND")

            for n <- nets do
              band = if n.frequency >= 5000, do: "5 GHz", else: "2.4 GHz"
              IO.puts(ctx, "#{String.pad_trailing(n.ssid, 32)} #{String.pad_trailing("#{n.signal} dBm", 9)} #{String.pad_trailing(n.security, 10)} #{band}")
            end

            0

          {:error, e} ->
            IO.err(ctx, "wifi: scan failed on #{iface}: #{inspect(e)}")
            1
        end
    end
  end

  # Saved networks are system settings: changing them is for root.
  defp wifi([cmd | _], ctx) when cmd in ~w(connect forget setup) and ctx.user != "root", do: Lepton.Users.denied(ctx, "wifi #{cmd}")

  defp wifi(["connect", ssid | rest], ctx) do
    # A saved network needs no passphrase again.
    pass =
      cond do
        rest != [] -> hd(rest)
        ssid in Lepton.Wifi.networks() -> :saved
        ctx.tty -> Lepton.Setup.read_secret(ctx, "Passphrase for #{ssid} (Enter for an open network): ")
        true -> ""
      end

    if pass == nil do
      IO.err(ctx, "wifi: cancelled")
      1
    else
      if pass != :saved, do: Lepton.Wifi.save(ssid, pass)
      Lepton.Wifi.select(ssid)

      case Lepton.Wifi.wireless_interfaces() do
        [] ->
          IO.puts(ctx, "Saved \"#{ssid}\". No Wi-Fi hardware yet: Lepton connects as soon as an adapter appears.")
          0

        [iface | _] ->
          IO.puts(ctx, if(pass == :saved, do: "Connecting to \"#{ssid}\" on #{iface}...", else: "Saved \"#{ssid}\". Connecting on #{iface}..."))

          with {:ok, st} <- Lepton.Wifi.await_associated(iface, 30_000),
               _ = IO.puts(ctx, "Associated with #{st["ssid"]}; asking for an address (DHCP)..."),
               {:ok, l} <- Lepton.Wifi.await_lease(iface, 20_000) do
            IO.puts(ctx, "Connected: #{iface} #{Lepton.Net.format_ip(l.ip)}/#{l.prefix}")
            0
          else
            {:error, :timeout} ->
              IO.err(ctx, "wifi: associated, but no DHCP address yet. Lepton keeps trying; `wifi` shows the status.")
              1

            {:error, state} ->
              IO.err(ctx, "wifi: not connected yet (#{state}). Lepton keeps trying; `wifi` shows the status.")
              1
          end
      end
    end
  end

  defp wifi(["forget" | rest], ctx) do
    case Lepton.Wifi.forget(List.first(rest)) do
      :ok ->
        IO.puts(ctx, if(rest == [], do: "Forgot all saved Wi-Fi networks.", else: "Forgot \"#{hd(rest)}\"."))
        0

      {:error, :not_found} ->
        IO.err(ctx, "wifi: \"#{hd(rest)}\" is not a saved network")
        1
    end
  end

  defp wifi(["setup" | _], ctx) do
    if ctx.tty, do: Lepton.Setup.wifi_prompt(ctx, false)
    0
  end

  defp wifi(args, ctx) when args in [[], ["status"]] do
    for line <- Lepton.Wifi.status_lines(), do: IO.puts(ctx, line)
    0
  end

  defp wifi(_, ctx) do
    IO.err(ctx, "usage: wifi [status] | scan [IFACE] | connect SSID [PASSPHRASE] | forget [SSID] | setup")
    2
  end

  defcmd "bluetooth", "Bluetooth: keyboards, mice and headphones: scan, pair, connect",
    usage: "bluetooth [status] | on | off | scan [SECONDS] | devices | pair DEVICE | connect DEVICE | disconnect DEVICE | forget DEVICE" do
    bluetooth(args, ctx)
  end

  @bt_usage "usage: bluetooth [status] | on | off | scan [SECONDS] | devices | pair DEVICE | connect DEVICE | disconnect DEVICE | forget DEVICE"
  @bt_changes ~w(on off pair connect disconnect forget)

  defp bluetooth([cmd | _], ctx) when cmd in @bt_changes and ctx.user != "root", do: Lepton.Users.denied(ctx, "bluetooth #{cmd}")

  defp bluetooth([cmd | _] = args, ctx) when cmd in @bt_changes do
    # Bluetooth comes as an app: install it the first time.
    with :ok <- bt_installed(ctx), :ok <- bt_ready(ctx) do
      bluetooth_change(args, ctx)
    else
      {:error, reason} -> bt_error(ctx, reason)
    end
  end

  defp bluetooth(args, ctx) when args in [[], ["status"]] do
    s = Lepton.Bluetooth.summary()

    cond do
      not Lepton.Apps.installed?("bluetooth") ->
        IO.puts(ctx, "Bluetooth isn't installed. Install it with: sudo app install bluetooth")

      s.adapter == nil ->
        IO.puts(ctx, if(s.running, do: "No Bluetooth adapter. Plug in a USB Bluetooth adapter (in UTM, pass it to the VM).", else: "Bluetooth is starting..."))

      true ->
        a = s.adapter
        IO.puts(ctx, "Bluetooth is #{if a.powered, do: "on", else: "off"}: #{a.name} (#{a.address})#{if a.discovering, do: ", looking for devices", else: ""}")

        for d <- Enum.filter(s.devices, & &1.paired) do
          IO.puts(ctx, "  #{bt_line(d)}")
        end

        if not Enum.any?(s.devices, & &1.paired), do: IO.puts(ctx, "No paired devices. Find one with: bluetooth scan")
    end

    0
  end

  defp bluetooth(["devices"], ctx) do
    case Lepton.Bluetooth.summary().devices do
      [] -> IO.puts(ctx, "No devices yet. Find some with: bluetooth scan")
      devices -> for d <- devices, do: IO.puts(ctx, bt_line(d))
    end

    0
  end

  defp bluetooth(["scan" | rest], ctx) do
    seconds = case rest do
      [n] -> case Integer.parse(n) do
          {s, ""} when s in 1..120 -> s
          _ -> nil
        end

      [] -> 10
      _ -> nil
    end

    cond do
      seconds == nil ->
        bt_error(ctx, @bt_usage)

      (result = Lepton.Bluetooth.discover(seconds)) != :ok ->
        bt_error(ctx, elem(result, 1))

      true ->
        IO.puts(ctx, "Looking for devices for #{seconds} seconds (put yours in pairing mode)...")
        bt_scan(ctx, System.monotonic_time(:millisecond) + seconds * 1000, MapSet.new())
    end
  end

  defp bluetooth(_, ctx) do
    IO.err(ctx, @bt_usage)
    2
  end

  # Devices as they are found.
  defp bt_scan(ctx, deadline, shown) do
    new = Enum.reject(Lepton.Bluetooth.summary().devices, &MapSet.member?(shown, &1.address))
    for d <- new, do: IO.puts(ctx, bt_line(d))
    shown = Enum.reduce(new, shown, &MapSet.put(&2, &1.address))

    if System.monotonic_time(:millisecond) < deadline do
      receive do
        {:signal, sig} when sig in [:int, :term] -> 130
      after
        1000 -> bt_scan(ctx, deadline, shown)
      end
    else
      if shown == MapSet.new(), do: IO.puts(ctx, "No devices found.")
      0
    end
  end

  defp bt_line(d) do
    state = cond do
      d.connected -> "connected"
      d.paired -> "paired"
      true -> "#{d.rssi || "?"} dBm"
    end

    battery = if d.battery, do: ", battery #{d.battery}%", else: ""
    "#{d.address}  #{String.pad_trailing(d.name, 28)} #{String.pad_trailing(to_string(d.kind), 11)} #{state}#{battery}"
  end

  defp bluetooth_change(["on"], ctx), do: bt_result(ctx, Lepton.Bluetooth.power(true), "Bluetooth is on.")
  defp bluetooth_change(["off"], ctx), do: bt_result(ctx, Lepton.Bluetooth.power(false), "Bluetooth is off.")

  defp bluetooth_change(["pair", what], ctx) do
    with {:ok, d} <- bt_device(ctx, what, true) do
      IO.puts(ctx, "Pairing with #{d.name} (#{d.address})...")
      me = self()
      pid = spawn(fn -> send(me, {:paired, self(), Lepton.Bluetooth.pair(d, me)}) end)

      case bt_pairing(ctx, pid) do
        :ok ->
          now = Enum.find(Lepton.Bluetooth.summary().devices, &(&1.address == d.address)) || d
          IO.puts(ctx, "Paired with #{d.name}#{if now.connected, do: ", and connected", else: " (connect it with: bluetooth connect #{d.address})"}.")
          0

        {:error, reason} ->
          bt_error(ctx, reason)
      end
    else
      {:error, reason} -> bt_error(ctx, reason)
    end
  end

  defp bluetooth_change([action, what], ctx) when action in ~w(connect disconnect forget) do
    with {:ok, d} <- bt_device(ctx, what, action == "connect") do
      {result, done} =
        case action do
          "connect" -> {Lepton.Bluetooth.connect(d), "Connected #{d.name}."}
          "disconnect" -> {Lepton.Bluetooth.disconnect(d), "Disconnected #{d.name}."}
          "forget" -> {Lepton.Bluetooth.forget(d), "Forgot #{d.name}: pair it again to use it."}
        end

      bt_result(ctx, result, done)
    else
      {:error, reason} -> bt_error(ctx, reason)
    end
  end

  defp bluetooth_change(_, ctx), do: bluetooth(:usage, ctx)

  # A device by address or name; one that isn't known yet is looked for (pairing, connecting).
  defp bt_device(ctx, what, look?) do
    case Lepton.Bluetooth.find(Lepton.Bluetooth.summary().devices, what) do
      {:ok, d} ->
        {:ok, d}

      {:error, _} when look? ->
        IO.puts(ctx, "Looking for #{what}...")

        with :ok <- Lepton.Bluetooth.discover(20) do
          Enum.find_value(1..20, {:error, "#{what} wasn't found (is it on, and in pairing mode?)"}, fn _ ->
            Process.sleep(1000)
            with {:ok, d} <- Lepton.Bluetooth.find(Lepton.Bluetooth.summary().devices, what), do: {:ok, d}, else: (_ -> nil)
          end)
        end

      error ->
        error
    end
  end

  # While pairing: the agent's questions, answered here.
  defp bt_pairing(ctx, pid) do
    receive do
      {:paired, ^pid, result} ->
        result

      {:bt_agent, from, ref, {member, name, args}} ->
        send(from, {:bt_answer, ref, bt_answer(ctx, member, name, args)})
        bt_pairing(ctx, pid)

      {:signal, sig} when sig in [:int, :term] ->
        Process.exit(pid, :kill)
        {:error, "cancelled"}
    end
  end

  defp bt_answer(ctx, "RequestPinCode", name, _args) do
    keyboard? = Enum.any?(Lepton.Bluetooth.summary().devices, &(&1.name == name and &1.kind == :keyboard))

    if keyboard? do
      # A keyboard proves itself by typing a PIN we make up.
      pin = :rand.uniform(999_999) |> Integer.to_string() |> String.pad_leading(6, "0")
      IO.puts(ctx, "On #{name}, type #{pin} and press Enter.")
      {:pin, pin}
    else
      {:pin, bt_ask(ctx, "PIN code for #{name} (0000 is common): ")}
    end
  end

  defp bt_answer(ctx, "DisplayPinCode", name, [pin]) do
    IO.puts(ctx, "On #{name}, type #{pin} and press Enter.")
    :ok
  end

  defp bt_answer(ctx, "DisplayPasskey", name, [passkey, entered]) do
    if entered == 0, do: IO.puts(ctx, "On #{name}, type #{bt_six(passkey)} and press Enter.")
    :ok
  end

  defp bt_answer(ctx, "RequestPasskey", name, _args) do
    case Integer.parse(bt_ask(ctx, "Passkey shown on #{name}: ")) do
      {n, ""} -> {:passkey, n}
      _ -> :no
    end
  end

  defp bt_answer(ctx, "RequestConfirmation", name, [passkey]), do: bt_yes(ctx, "Does #{name} show #{bt_six(passkey)}? [Y/n] ")
  defp bt_answer(ctx, "RequestAuthorization", name, _args), do: bt_yes(ctx, "Pair with #{name}? [Y/n] ")

  defp bt_answer(ctx, "Cancel", _name, _args) do
    IO.puts(ctx, "The device cancelled pairing.")
    :ok
  end

  defp bt_answer(_ctx, _member, _name, _args), do: :no

  defp bt_six(n), do: n |> Integer.to_string() |> String.pad_leading(6, "0")

  defp bt_ask(ctx, prompt) do
    IO.write(ctx, prompt)

    case IO.read_line(ctx) do
      line when is_binary(line) -> String.trim(line)
      _ -> ""
    end
  end

  defp bt_yes(ctx, prompt), do: if(String.downcase(bt_ask(ctx, prompt)) in ["", "y", "yes"], do: :yes, else: :no)

  defp bt_installed(ctx) do
    if Lepton.Apps.installed?("bluetooth") do
      :ok
    else
      IO.puts(ctx, "Installing Bluetooth support (BlueZ: about 8 MB to download)...")

      case Lepton.Apps.install("bluetooth", &IO.puts(ctx, &1)) do
        :ok -> :ok
        {:error, reason} -> {:error, "couldn't install Bluetooth: #{reason}"}
      end
    end
  end

  # The service starts the daemons within a few seconds of the install.
  defp bt_ready(ctx) do
    if Lepton.Bluetooth.summary().adapter do
      :ok
    else
      Enum.find_value(1..20, fn i ->
        if i == 3, do: IO.puts(ctx, "Waiting for Bluetooth to start...")
        Process.sleep(500)
        if Lepton.Bluetooth.summary().adapter, do: :ok
      end) || {:error, if(Lepton.Bluetooth.summary().running, do: "no Bluetooth adapter (plug in a USB Bluetooth adapter; in UTM, pass it to the VM)", else: "Bluetooth didn't start (see /var/log/messages)")}
    end
  end

  defp bt_result(ctx, :ok, message) do
    IO.puts(ctx, message)
    0
  end

  defp bt_result(ctx, {:error, reason}, _), do: bt_error(ctx, reason)

  defp bt_error(ctx, reason) do
    IO.err(ctx, if(String.starts_with?(reason, "usage:"), do: reason, else: "bluetooth: #{reason}"))
    1
  end

  # -- users and sudo ------------------------------------------------------------------------

  defcmd "sudo", "run a command as root, after asking for your password",
    usage: "sudo [-S] COMMAND [ARG...] | sudo [-S] -i | -s | sudo -k | -v | -l" do
    sudo(args, ctx, %{})
  end

  defp sudo(["-S" | rest], ctx, o), do: sudo(rest, ctx, Map.put(o, :stdin, true))
  defp sudo(["-n" | rest], ctx, o), do: sudo(rest, ctx, Map.put(o, :noninteractive, true))
  defp sudo(["--" | rest], ctx, o), do: sudo_run(rest, ctx, o)

  defp sudo(["-k" | _], ctx, _o) do
    Lepton.Users.sudo_reset(ctx.user)
    0
  end

  defp sudo(["-l" | _], ctx, _o) do
    if Lepton.Users.sudoer?(ctx.user),
      do: (IO.puts(ctx, "User #{ctx.user} may run any command as root (password asked every 5 minutes per terminal)."); 0),
      else: (IO.err(ctx, "User #{ctx.user} may not run sudo on #{Lepton.Sys.hostname()}."); 1)
  end

  defp sudo([flag | _], ctx, o) when flag in ["-v", "-i", "-s"] do
    with {:ok, root} <- sudo_auth(ctx, o) do
      case flag do
        "-v" -> 0
        "-i" -> Lepton.Shell.interactive(Lepton.Users.as(root, Lepton.Users.get("root"), login: true))
        "-s" -> Lepton.Shell.interactive(root)
      end
    end
  end

  defp sudo(["-" <> _ = flag | _], ctx, _o) when flag != "-" do
    IO.err(ctx, "sudo: unknown option #{flag}\nusage: sudo [-S] COMMAND [ARG...] | sudo -i | -s | -k | -v | -l")
    1
  end

  defp sudo(cmd, ctx, o), do: sudo_run(cmd, ctx, o)

  defp sudo_run([], ctx, _o) do
    IO.err(ctx, "usage: sudo [-S] COMMAND [ARG...] | sudo -i | -s | -k | -v | -l")
    1
  end

  defp sudo_run([name | rest], ctx, o) do
    with {:ok, root} <- sudo_auth(ctx, o) do
      Lepton.Shell.Exec.exec(name, rest, %Lepton.Shell{ctx: root})
    end
  end

  # {:ok, root context} once the user's password checks out (or is fresh),
  # or the exit status to return.
  defp sudo_auth(ctx, o) do
    user = ctx.user
    terminal = ctx.tty || ctx.stdin
    root = Lepton.Users.as(ctx, Lepton.Users.get("root"))
    root = %{root | env: Map.merge(root.env, %{"SUDO_USER" => user, "SUDO_UID" => to_string((Lepton.Users.get(user) || %{uid: 0}).uid)})}

    cond do
      user == "root" ->
        {:ok, root}

      not Lepton.Users.sudoer?(user) ->
        IO.err(ctx, "sudo: #{user} is not allowed to run sudo (not in the sudo group).")
        1

      Lepton.Users.sudo_fresh?(user, terminal) ->
        {:ok, root}

      o[:noninteractive] ->
        IO.err(ctx, "sudo: a password is required")
        1

      true ->
        sudo_ask(ctx, o, user, terminal, root, 1)
    end
  end

  defp sudo_ask(ctx, _o, _user, _terminal, _root, 4) do
    IO.err(ctx, "sudo: 3 incorrect password attempts")
    1
  end

  defp sudo_ask(ctx, o, user, terminal, root, attempt) do
    prompt = "[sudo] password for #{user}: "

    password =
      cond do
        o[:stdin] ->
          Elixir.IO.write(ctx.stderr, prompt)

          case IO.read_line(ctx.stdin) do
            line when is_binary(line) -> String.trim_trailing(line, "\n")
            _ -> nil
          end

        ctx.tty ->
          Lepton.Setup.read_secret(ctx, prompt)

        true ->
          IO.err(ctx, "sudo: a terminal is required to read the password; use the -S option to read it from standard input")
          :no_terminal
      end

    cond do
      password == :no_terminal -> 1
      password == nil -> 1
      Lepton.Users.verify(user, password) ->
        Lepton.Users.sudo_touch(user, terminal)
        {:ok, root}

      true ->
        Process.sleep(1000)
        IO.err(ctx, "Sorry, try again.")
        sudo_ask(ctx, o, user, terminal, root, attempt + 1)
    end
  end

  defcmd "su", "become another user (default root) in a new shell; exit or C-d returns",
    usage: "su [-|-l] [USER] [-c COMMAND]" do
    {login?, rest} =
      case args do
        [flag | rest] when flag in ["-", "-l", "--login"] -> {true, rest}
        rest -> {false, rest}
      end

    {command, rest} =
      case Enum.split_while(rest, &(&1 != "-c")) do
        {before, ["-c", cmd | _]} -> {cmd, before}
        {before, _} -> {nil, before}
      end

    name = List.first(rest) || "root"

    with %Lepton.Users{} = target <- Lepton.Users.get(name) || {:error, "su: user #{name} does not exist"},
         :ok <- su_auth(ctx, target) do
      new_ctx = Lepton.Users.as(ctx, target, login: login?)

      cond do
        command ->
          Lepton.Shell.run_string(command, cwd: new_ctx.cwd, env: new_ctx.env, stdin: ctx.stdin, stdout: ctx.stdout, stderr: ctx.stderr, tty: ctx.tty, user: target.name)

        ctx.tty == nil ->
          IO.err(ctx, "su: a terminal is required for a shell (use -c COMMAND)")
          1

        true ->
          # A new shell; when it exits (exit, C-d) we are back where we were.
          Lepton.Shell.interactive(new_ctx)
      end
    else
      {:error, msg} -> IO.err(ctx, msg); 1
    end
  end

  # Root may become anyone; others need the target's password (root has
  # none: use sudo su -).
  defp su_auth(%{user: "root"}, _target), do: :ok

  defp su_auth(_ctx, %{name: "root"}), do: {:error, "su: Authentication failure (root has no password; use: sudo su -)"}

  defp su_auth(ctx, target) do
    password = if ctx.tty, do: Lepton.Setup.read_secret(ctx, "Password: "), else: nil

    if password && Lepton.Users.verify(target.name, password),
      do: :ok,
      else: (Process.sleep(1000); {:error, "su: Authentication failure"})
  end

  defcmd "passwd", "change your password (root: anyone's)", usage: "passwd [--stdin] [USER]" do
    {opts, rest} = getopt(args, "")
    target = List.first(rest) || ctx.user
    stdin? = opts["stdin"] == true

    cond do
      target != ctx.user and ctx.user != "root" ->
        Lepton.Users.denied(ctx, "passwd #{target}")

      Lepton.Users.get(target) == nil or target == "root" ->
        IO.err(ctx, "passwd: user '#{target}' does not exist#{if target == "root", do: " (root has no password; use sudo)", else: ""}")
        1

      stdin? and ctx.user == "root" ->
        set_new_password(ctx, target, read_stdin_line(ctx))

      ctx.tty == nil ->
        IO.err(ctx, "passwd: run it on a terminal (root may use --stdin)")
        1

      true ->
        current_ok = ctx.user == "root" or Lepton.Users.verify(target, Lepton.Setup.read_secret(ctx, "Current password: ") || "")

        if current_ok do
          new = Lepton.Setup.read_secret(ctx, "New password: ")
          again = Lepton.Setup.read_secret(ctx, "Retype new password: ")
          if new == again, do: set_new_password(ctx, target, new), else: (IO.err(ctx, "passwd: the passwords don't match"); 1)
        else
          Process.sleep(1000)
          IO.err(ctx, "passwd: authentication failure")
          1
        end
    end
  end

  defp read_stdin_line(ctx) do
    case IO.read_line(ctx.stdin) do
      line when is_binary(line) -> String.trim_trailing(line, "\n")
      _ -> nil
    end
  end

  defp set_new_password(ctx, name, password) when is_binary(password) and byte_size(password) >= 4 do
    Lepton.Users.set_password(name, password)
    IO.puts(ctx, "passwd: password updated for #{name}")
    0
  end

  defp set_new_password(ctx, _name, _password) do
    IO.err(ctx, "passwd: use a password of at least 4 characters")
    1
  end

  defcmd "useradd", "create a user account (and its home)", usage: "useradd [--sudo] [-c FULL_NAME] [--password-stdin] NAME",
    aliases: ["adduser"], root: true do
    {opts, rest} = getopt(args, "c:")

    with [name] <- rest,
         password when is_binary(password) <-
           (if opts["password-stdin"], do: read_stdin_line(ctx), else: ctx.tty && Lepton.Setup.read_secret(ctx, "Password for #{name}: ")),
         {:ok, user} <- Lepton.Users.create(name, password, gecos: opts["c"] || name, sudo: opts["sudo"] == true) do
      Lepton.Users.sync_etc()
      IO.puts(ctx, "Created #{user.name} (uid #{user.uid}, home #{user.home})#{if opts["sudo"], do: ", allowed to use sudo", else: ""}.")
      0
    else
      {:error, msg} -> IO.err(ctx, "useradd: " <> msg); 1
      _ -> IO.err(ctx, "usage: useradd [--sudo] [-c FULL_NAME] [--password-stdin] NAME (asks for the password on a terminal)"); 2
    end
  end

  defcmd "userdel", "delete a user account", usage: "userdel [-r] NAME", aliases: ["deluser"], root: true do
    {opts, rest} = getopt(args, "r")

    case rest do
      [name] ->
        case Lepton.Users.delete(name, remove_home: opts["r"] == true) do
          :ok -> Lepton.Users.sync_etc(); IO.puts(ctx, "Deleted #{name}#{if opts["r"], do: " and its home", else: ""}."); 0
          {:error, msg} -> IO.err(ctx, "userdel: " <> msg); 1
        end

      _ ->
        IO.err(ctx, "usage: userdel [-r] NAME")
        2
    end
  end

  defcmd "credits", "who made Lepton", usage: "credits" do
    IO.puts(ctx, Lepton.credits())
    0
  end
end
