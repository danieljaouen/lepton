defmodule Lepton.Player.CLI do
  @moduledoc """
  `play` in a terminal: a status line under the playlist while it plays
  (keys as in the window: Space pauses, Left/Right seek 5 seconds,
  Up/Down a minute, `n`/`p` the next or previous file, `9`/`0` the volume,
  `m` mutes, `q` stops), and with no files, a list of the media in a
  folder to choose from (the desktop's Media Player opens this).
  """

  alias Lepton.{FFmpeg, Player, Sound, TTY}

  @media ~w(.mp4 .m4v .mkv .webm .mov .avi .mpg .mpeg .ts .wmv .flv .ogv .3gp .mp3 .m4a .aac .flac .ogg .oga .opus .wav .wma .aiff .aif .mka .m3u .m3u8 .pls)

  @doc "Is `path` a file `play` plays (by its extension)?"
  def media?(path), do: String.downcase(Path.extname(path)) in @media

  @doc """
  Play `items` (paths or addresses) one after another. Options: `:video`
  (open windows for videos, on the desktop), `:start` (seconds into the
  first), `:icy` (radio streams), `:titles` (a title for each item).
  Returns the exit status.
  """
  def run(ctx, items, opts \\ []) do
    tty = interactive(ctx)
    if tty, do: TTY.set_mode(tty, :raw)

    try do
      play_list(ctx, tty, items, 0, opts, 0)
    after
      if tty do
        TTY.write(tty, "\r\e[2K\e[?25h")
        TTY.set_mode(tty, :cooked)
      end
    end
  end

  defp interactive(ctx), do: if(ctx.tty && is_pid(ctx.tty) && Process.alive?(ctx.tty), do: ctx.tty)

  defp play_list(_ctx, _tty, items, i, _opts, status) when i >= length(items) or i < 0, do: status

  defp play_list(ctx, tty, items, i, opts, status) do
    url = Enum.at(items, i)
    title = Enum.at(opts[:titles] || [], i)
    start = if i == 0, do: opts[:start], else: nil

    case open(ctx, url, title, start, opts) do
      {:ok, pid} ->
        result = watch(ctx, tty, pid, i, length(items))
        Player.stop(pid)

        case result do
          :next -> play_list(ctx, tty, items, i + 1, opts, status)
          :previous -> play_list(ctx, tty, items, max(i - 1, 0), opts, status)
          :ended -> play_list(ctx, tty, items, i + 1, opts, status)
          {:error, why} -> say(ctx, tty, "play: #{url}: #{why}"); play_list(ctx, tty, items, i + 1, opts, 1)
          :quit -> status
        end

      {:error, why} ->
        say(ctx, tty, "play: #{why}")
        play_list(ctx, tty, items, i + 1, opts, 1)
    end
  end

  defp say(ctx, tty, text) do
    if tty, do: TTY.write(tty, "\r\e[2K"), else: :ok
    Lepton.IO.err(ctx, text)
  end

  @doc false
  # Start a player for `url`: what it holds (ffprobe), a window if it has
  # pictures and there's a desktop.
  def open(ctx, url, title, start, opts) do
    url = if url =~ ~r{^[a-z][a-z0-9+.-]*://}i, do: url, else: Lepton.Ctx.path(ctx, url)

    cond do
      why = FFmpeg.missing() ->
        {:error, why}

      not (url =~ ~r{^[a-z][a-z0-9+.-]*://}i) and not File.regular?(url) ->
        {:error, "#{url}: no such file"}

      true ->
        live? = opts[:icy] || false

        info =
          cond do
            live? -> %{duration: nil, title: nil, artist: nil, album: nil, audio: true, video: nil}
            true -> case FFmpeg.probe(url, ctx.user) do
                {:ok, i} -> i
                {:error, _} -> nil
              end
          end

        if info == nil do
          {:error, "can't play #{Path.basename(url)} (FFmpeg can't read it)"}
        else
          env = ctx.env
          window = opts[:video] != false and info.video != nil and (env["WAYLAND_DISPLAY"] || "") != ""
          live = live? or (info.duration == nil and url =~ ~r{^[a-z]+://}i)
          Player.start(url, info: info, title: title, live: live, icy: opts[:icy] || false, start: start, window: window, env: env, user: ctx.user)
        end
    end
  end

  # Until it ends, or a key says otherwise.
  defp watch(ctx, tty, pid, i, n) do
    ref = Process.monitor(pid)
    status = Player.status(pid)
    loop(ctx, tty, pid, ref, status, i, n)
  end

  defp loop(ctx, tty, pid, ref, status, i, n) do
    status = drain(pid, status)
    if tty, do: TTY.write(tty, ["\r\e[2K", line(status, i, n, elem(TTY.size(tty), 1))])

    cond do
      # A video ended with its window open: it waits there (Space, or its
      # play button, plays it again) until the window is closed, or q.
      status.state == :ended and status.window ->
        wait_or_key(ctx, tty, pid, ref, status, i, n)

      status.state == :ended ->
        :ended

      status.state == :error ->
        {:error, status.error}

      true ->
        event =
          if tty do
            case TTY.read_key(tty, 250) do
              :timeout -> nil
              key -> key
            end
          else
            receive do
              {:player, ^pid, s} -> send(self(), {:player, pid, s}); nil
              {:DOWN, ^ref, _, _, _} -> :gone
            end
          end

        case key(pid, event) do
          :continue -> loop(ctx, tty, pid, ref, status, i, n)
          result -> result
        end
    end
  end

  defp wait_or_key(ctx, tty, pid, ref, status, i, n) do
    event =
      if tty do
        case TTY.read_key(tty, 250) do
          :timeout -> nil
          key -> key
        end
      else
        receive do
          {:player, ^pid, s} -> send(self(), {:player, pid, s}); nil
          {:DOWN, ^ref, _, _, _} -> :gone
        end
      end

    case key(pid, event) do
      :continue -> loop(ctx, tty, pid, ref, status, i, n)
      result -> result
    end
  end

  defp drain(pid, status) do
    receive do
      {:player, ^pid, s} -> drain(pid, s)
    after
      0 -> status
    end
  end

  @doc false
  def key(pid, key) do
    case key do
      nil -> :continue
      :gone -> :ended
      " " -> Player.toggle(pid); :continue
      "SPC" -> Player.toggle(pid); :continue
      k when k in ["<left>", "h"] -> Player.seek(pid, -5); :continue
      k when k in ["<right>", "l"] -> Player.seek(pid, 5); :continue
      k when k in ["<up>", "k"] -> Player.seek(pid, 60); :continue
      k when k in ["<down>", "j"] -> Player.seek(pid, -60); :continue
      k when k in ["0", "+", "="] -> Sound.change(5); :continue
      k when k in ["9", "-"] -> Sound.change(-5); :continue
      "m" -> Sound.mute(:toggle); :continue
      k when k in ["n", ">", "RET"] -> :next
      k when k in ["p", "<"] -> :previous
      k when k in ["q", "ESC", "C-c", "C-d"] -> :quit
      _ -> :continue
    end
  end

  @doc "The status line: state, title, position, a progress bar, the volume."
  def line(s, i, n, cols) do
    icon = case s.state do
      :playing -> "▶"
      :paused -> "⏸"
      _ -> "■"
    end

    s = if s.state == :ended and s[:window], do: %{s | title: "#{s.title} (ended: Space plays it again; close its window or q)"}, else: s

    vol = Sound.status()
    vol = if vol.muted, do: "muted", else: "vol #{vol.volume}%"
    which = if n > 1, do: "[#{i + 1}/#{n}] ", else: ""
    title = Enum.join(Enum.reject([s.title, s.now_playing], &(&1 in [nil, ""])), " - ")
    title = if s.error && s.state != :error, do: "#{title} (#{s.error})", else: title

    right =
      if s.live || s.duration == nil do
        "  live  #{vol}"
      else
        width = 20
        done = round(width * min((s.position || 0) / max(s.duration, 0.001), 1.0))
        "  #{Player.clock(s.position)} / #{Player.clock(s.duration)} [#{String.duplicate("=", done)}#{String.duplicate("-", width - done)}] #{vol}"
      end

    left = "#{icon} #{which}"
    room = max(cols - String.length(left) - String.length(right) - 1, 8)
    title = if String.length(title) > room, do: String.slice(title, 0, room - 1) <> "…", else: title
    left <> title <> right
  end

  # -- choosing ------------------------------------------------------------------------------

  @doc """
  The folder view `play` opens with no files: the media and folders in
  `dir`; Enter plays a file (and those after it, as a playlist) or opens
  a folder, Backspace goes up, `q` quits.
  """
  def choose(ctx, dir, opts \\ []) do
    tty = interactive(ctx)

    if tty == nil do
      Lepton.IO.err(ctx, "usage: play [--no-video] [--start TIME] FILE|URL...")
      2
    else
      TTY.set_mode(tty, :raw)
      TTY.write(tty, "\e[?1049h\e[?25l")

      try do
        browse(ctx, tty, %{dir: dir, sel: 0, top: 0, message: nil}, opts)
      after
        TTY.write(tty, "\e[0m\e[?25h\e[?1049l")
        TTY.set_mode(tty, :cooked)
      end
    end
  end

  @doc false
  def entries(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names = Enum.reject(names, &String.starts_with?(&1, "."))
        dirs = names |> Enum.filter(&File.dir?(Path.join(dir, &1))) |> Enum.sort_by(&String.downcase/1) |> Enum.map(&{:dir, &1})
        files = names |> Enum.filter(&(media?(&1) and File.regular?(Path.join(dir, &1)))) |> Enum.sort_by(&String.downcase/1) |> Enum.map(&{:file, &1})
        dirs ++ files

      _ ->
        []
    end
  end

  defp browse(ctx, tty, st, opts) do
    {rows, cols} = TTY.size(tty)
    list = [{:dir, ".."} | entries(st.dir)]
    sel = st.sel |> max(0) |> min(length(list) - 1)
    height = max(rows - 4, 1)
    top = cond do
      sel < st.top -> sel
      sel >= st.top + height -> sel - height + 1
      true -> st.top
    end

    st = %{st | sel: sel, top: top}
    head = "\e[1m Media Player\e[0m  #{st.dir}"
    body =
      for {{kind, name}, i} <- list |> Enum.with_index() |> Enum.slice(top, height) do
        label = if kind == :dir, do: name <> "/", else: name
        label = String.slice(label, 0, cols - 3)
        if i == sel, do: "\e[7m #{String.pad_trailing(label, cols - 2)}\e[0m", else: " #{label}"
      end

    foot = st.message || "Enter: play or open   Backspace: up   q: quit   (files play one after another)"
    screen = [head, "" | body] ++ List.duplicate("", height - length(body)) ++ ["\e[2m" <> String.slice(foot, 0, cols) <> "\e[0m"]
    TTY.write(tty, ["\e[H\e[2J", Enum.join(screen, "\r\n")])

    case TTY.read_key(tty) do
      k when k in ["q", "ESC", "C-c"] -> 0
      k when k in ["<down>", "j", "C-n"] -> browse(ctx, tty, %{st | sel: sel + 1, message: nil}, opts)
      k when k in ["<up>", "k", "C-p"] -> browse(ctx, tty, %{st | sel: sel - 1, message: nil}, opts)
      k when k in ["<next>", "C-v"] -> browse(ctx, tty, %{st | sel: sel + height, message: nil}, opts)
      k when k in ["<prior>", "M-v"] -> browse(ctx, tty, %{st | sel: sel - height, message: nil}, opts)
      k when k in ["DEL", "h", "<left>"] -> browse(ctx, tty, %{st | dir: Path.dirname(st.dir), sel: 0, top: 0, message: nil}, opts)
      k when k in ["RET", "l", "<right>"] ->
        case Enum.at(list, sel) do
          {:dir, ".."} -> browse(ctx, tty, %{st | dir: Path.dirname(st.dir), sel: 0, top: 0}, opts)
          {:dir, d} -> browse(ctx, tty, %{st | dir: Path.join(st.dir, d), sel: 0, top: 0}, opts)
          {:file, _} ->
            files = for {:file, f} <- Enum.drop(list, sel), do: Path.join(st.dir, f)
            TTY.write(tty, ["\e[H\e[2J", "\e[1m Media Player\e[0m  #{st.dir}\r\n\r\n", "\e[2mSpace: pause   Left/Right: 5 s   Up/Down: 1 min   n/p: next/previous   9/0: volume   q: back\e[0m\r\n\r\n"])
            TTY.write(tty, "\e[?25l")
            status = play_list(ctx, tty, files, 0, opts, 0)
            browse(ctx, tty, %{st | message: if(status != 0, do: "Something couldn't be played (see the message above, or ~/.cache/lepton/ffmpeg.log)")}, opts)
        end

      _ -> browse(ctx, tty, st, opts)
    end
  end
end
