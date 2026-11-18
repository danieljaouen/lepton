defmodule Lepton.Commands.Desktop do
  @moduledoc "The graphical desktop: Photon, Lepton's Wayland compositor."

  use Lepton.Command
  alias Lepton.{Photon, Users}
  alias Lepton.Photon.{Output, Term}

  defcmd "photon", "the graphical desktop (Photon, a Wayland compositor) and its terminal windows",
    usage: "photon [start] | term [COMMAND...] | info | screenshot FILE.png | stop" do
    photon(args, ctx)
  end

  defp photon(args, ctx) when args in [[], ["start"]] do
    with nil <- Process.whereis(Photon),
         {:ok, out} <- Output.framebuffer() do
      dir = runtime_dir(ctx)
      env = Map.merge(ctx.env, %{"XDG_RUNTIME_DIR" => dir, "WAYLAND_DISPLAY" => "wayland-0"})
      open = fn -> Term.start(env: env, user: ctx.user, cwd: env["HOME"]) end

      opts = [output: out, socket: Path.join(dir, "wayland-0"), input: :evdev, spawn: open, name: Photon, console: true, session: self()]

      case Photon.start(opts) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          open.()
          IO.puts(ctx, "Photon is running on the display (#{out.width}x#{out.height}). Ctrl+Alt+Backspace quits.")
          wait(ref, pid, ctx)

        {:error, reason} ->
          IO.err(ctx, "photon: #{reason}")
          1
      end
    else
      pid when is_pid(pid) ->
        IO.err(ctx, "photon: already running (open a terminal with: photon term)")
        1

      {:error, reason} ->
        IO.err(ctx, "photon: #{reason}")
        1
    end
  end

  defp photon(["term" | command], ctx) do
    with {:ok, env} <- session_env(ctx),
         {:ok, _} <- Term.start(env: env, user: ctx.user, cwd: ctx.cwd, command: if(command != [], do: Enum.join(command, " "))) do
      0
    else
      {:error, reason} when is_binary(reason) ->
        IO.err(ctx, "photon: #{reason}")
        1

      {:error, reason} ->
        IO.err(ctx, "photon: cannot open a terminal: #{inspect(reason)}")
        1
    end
  end

  defp photon(["info"], ctx) do
    case Process.whereis(Photon) do
      nil ->
        IO.puts(ctx, "Photon is not running. Start it with: photon")
        0

      pid ->
        info = Photon.info(pid)
        {w, h} = info.output
        IO.puts(ctx, "Photon: #{w}x#{h}, socket #{info.socket}")
        IO.puts(ctx, "#{info.clients} client(s), #{length(info.windows)} window(s)")

        for win <- info.windows do
          mark = if win.focused, do: "*", else: " "
          IO.puts(ctx, " #{mark} #{String.pad_trailing(win.title || "(untitled)", 30)} #{String.pad_trailing(win.app_id || "", 14)} #{win.width}x#{win.height} at #{win.x},#{win.y}")
        end

        0
    end
  end

  defp photon(["screenshot", file], ctx) do
    path = Lepton.Ctx.path(ctx, file)

    cond do
      Process.whereis(Photon) == nil ->
        IO.err(ctx, "photon: not running")
        1

      Users.check_write(ctx, path) != :ok ->
        IO.err(ctx, "photon: #{file}: permission denied")
        1

      true ->
        File.write!(path, Photon.screenshot(Photon))
        IO.puts(ctx, "Saved #{file}")
        0
    end
  end

  defp photon(["stop"], ctx) do
    case Process.whereis(Photon) do
      nil ->
        IO.err(ctx, "photon: not running")
        1

      pid ->
        GenServer.stop(pid)
        0
    end
  end

  defp photon(_args, ctx) do
    IO.err(ctx, "usage: photon [start] | term [COMMAND...] | info | screenshot FILE.png | stop")
    2
  end

  defp wait(ref, pid, ctx) do
    receive do
      {:DOWN, ^ref, _, _, _} ->
        IO.puts(ctx, "Photon stopped.")
        0

      {:signal, sig} when sig in [:int, :term] ->
        GenServer.stop(pid)
        wait(ref, pid, ctx)

      _ ->
        wait(ref, pid, ctx)
    end
  end

  # The environment Wayland clients need: from this shell (inside Photon) or the running Photon.
  defp session_env(ctx) do
    cond do
      ctx.env["WAYLAND_DISPLAY"] && ctx.env["XDG_RUNTIME_DIR"] ->
        {:ok, ctx.env}

      pid = Process.whereis(Photon) ->
        socket = Photon.info(pid).socket
        {:ok, Map.merge(ctx.env, %{"XDG_RUNTIME_DIR" => Path.dirname(socket), "WAYLAND_DISPLAY" => Path.basename(socket)})}

      true ->
        {:error, "Photon is not running (start it with: photon)"}
    end
  end

  # $XDG_RUNTIME_DIR: /run/user/UID, private to the user.
  defp runtime_dir(ctx) do
    uid = case Users.get(ctx.user) do
      %Users{uid: uid} -> uid
      nil -> 0
    end

    dir = if Lepton.Sys.native?(), do: "/run/user/#{uid}", else: Path.join(System.tmp_dir!(), "lepton-run-#{uid}")
    File.mkdir_p!(dir)
    File.chmod(dir, 0o700)
    dir
  end
end
