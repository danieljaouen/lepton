defmodule Lepton.Commands.Media do
  @moduledoc "Sound and pictures: the media player, internet radio, torrents."

  use Lepton.Command
  alias Lepton.{Player, Radio}
  alias Lepton.Player.CLI

  defcmd "play", "the media player: videos (in a window, on the desktop) and music, files or addresses (needs the ffmpeg app)",
    usage: "play [--no-video] [--start TIME] [FILE|URL...]" do
    case play_opts(args, %{video: true, start: nil, items: []}) do
      {:error, msg} ->
        IO.err(ctx, "play: " <> msg)
        2

      %{items: []} = o ->
        # (the desktop's Media Player: offered FFmpeg first, if it lacks it;
        # without, WAV files still play)
        ensure_ffmpeg(ctx, "The media player plays videos and music with FFmpeg")
        CLI.choose(ctx, start_dir(ctx), video: o.video)

      o ->
        items = Enum.flat_map(o.items, &expand(ctx, &1))

        cond do
          items == [] ->
            IO.err(ctx, "play: nothing to play")
            1

          # WAV files only: Lepton plays them itself, without FFmpeg (as `play` always has).
          o.start == nil and Enum.all?(items, &(String.downcase(Path.extname(&1)) == ".wav" and not (&1 =~ ~r{^[a-z]+://}i))) ->
            Lepton.Commands.Desktop.play_wavs(ctx, items)

          true ->
            if ensure_ffmpeg(ctx, "play plays these with FFmpeg"), do: CLI.run(ctx, items, video: o.video, start: o.start), else: 1
        end
    end
  end

  defp play_opts(["--no-video" | rest], o), do: play_opts(rest, %{o | video: false})
  defp play_opts(["-n" | rest], o), do: play_opts(rest, %{o | video: false})

  defp play_opts([s, t | rest], o) when s in ["--start", "-s"] do
    case time(t) do
      nil -> {:error, "--start takes a time: SECONDS, M:SS or H:MM:SS"}
      sec -> play_opts(rest, %{o | start: sec})
    end
  end

  defp play_opts(["--" | rest], o), do: %{o | items: o.items ++ rest}
  defp play_opts(["-" <> _ = flag | _], _o) when flag != "-", do: {:error, "unknown option #{flag}"}
  defp play_opts([item | rest], o), do: play_opts(rest, %{o | items: o.items ++ [item]})
  defp play_opts([], o), do: o

  @doc false
  def time(t) do
    parts = String.split(t, ":")

    with true <- length(parts) <= 3,
         nums = Enum.map(parts, &Float.parse/1),
         true <- Enum.all?(nums, &match?({_, ""}, &1)) do
      nums |> Enum.map(&elem(&1, 0)) |> Enum.reduce(0.0, &(&2 * 60 + &1))
    else
      _ -> nil
    end
  end

  # A folder: the media in it; a playlist file stays (ffmpeg reads it).
  defp expand(ctx, item) do
    path = Lepton.Ctx.path(ctx, item)

    cond do
      item =~ ~r{^[a-z][a-z0-9+.-]*://}i -> [item]
      File.dir?(path) -> for {:file, f} <- CLI.entries(path), do: Path.join(path, f)
      true -> [item]
    end
  end

  defp start_dir(ctx) do
    home = Lepton.Ctx.home(ctx)
    cwd = ctx.cwd || home

    cond do
      Enum.any?(CLI.entries(cwd), &match?({:file, _}, &1)) -> cwd
      File.dir?(Path.join(home, "Videos")) -> Path.join(home, "Videos")
      File.dir?(Path.join(home, "Music")) -> Path.join(home, "Music")
      true -> cwd
    end
  end

  defcmd "radio", "internet radio: your stations, a search of 50,000 more, the song playing (needs the ffmpeg app)",
    usage: "radio [STATION|URL] | list | search WORDS... | add NAME URL | rm NAME" do
    case args do
      [] ->
        cond do
          !(ctx.tty && is_pid(ctx.tty)) -> IO.err(ctx, "usage: radio STATION|URL (or radio, in a terminal, to choose)"); 2
          ensure_ffmpeg(ctx, "The radio plays stations with FFmpeg") -> Radio.ui(ctx)
          true -> 1
        end

      ["list"] ->
        for {name, url} <- Radio.stations(ctx), do: IO.puts(ctx, "#{name}\t#{url}")
        0

      ["search" | words] when words != [] ->
        case Radio.search(Enum.join(words, " ")) do
          {:ok, []} ->
            IO.puts(ctx, "Nothing found.")
            1

          {:ok, found} ->
            for s <- found do
              extra = Enum.join(Enum.reject([s.country, s.codec, if(s.bitrate > 0, do: "#{s.bitrate}k")], &(&1 in [nil, ""])), " ")
              IO.puts(ctx, "#{s.name}  (#{extra})\n    #{s.url}")
            end

            0

          {:error, why} ->
            IO.err(ctx, "radio: " <> why)
            1
        end

      ["add", name, url] ->
        if url =~ ~r{^https?://}i do
          Radio.add(ctx, name, url)
          IO.puts(ctx, "Added #{name}.")
          0
        else
          IO.err(ctx, "radio: #{url} isn't a web address (http:// or https://)")
          2
        end

      [rm, name] when rm in ["rm", "remove"] ->
        case Radio.remove(ctx, name) do
          :ok -> IO.puts(ctx, "Removed #{name}."); 0
          {:error, :none} -> IO.err(ctx, "radio: no station called #{name}"); 1
          {:error, why} -> IO.err(ctx, "radio: #{inspect(why)}"); 1
        end

      [cmd | _] when cmd in ["add", "rm", "remove", "search", "list"] ->
        IO.err(ctx, "usage: radio [STATION|URL] | list | search WORDS... | add NAME URL | rm NAME")
        2

      words ->
        with true <- ensure_ffmpeg(ctx, "The radio plays stations with FFmpeg") || :missing,
             {:ok, station} <- Radio.find(ctx, Enum.join(words, " ")) do
          Radio.play(ctx, station)
        else
          :missing -> 1
          {:error, why} -> IO.err(ctx, "radio: " <> why); 1
        end
    end
  end

  defcmd "torrent", "BitTorrent: download from magnet links and .torrent files, and share back while they stay added",
    usage: "torrent [add [-d DIR] [--peer HOST:PORT] MAGNET|FILE|URL | list | stop T | start T | rm [--delete] T | info FILE | create [-o FILE] [-t TRACKER]... PATH]" do
    torrent(ctx, args)
  end

  defp torrent(ctx, []) do
    if ctx.tty && is_pid(ctx.tty) do
      Lepton.Torrent.CLI.run(ctx)
    else
      torrent(ctx, ["list"])
    end
  end

  defp torrent(ctx, ["add" | rest]) do
    case add_opts(rest, %{dir: nil, peers: [], sources: []}) do
      {:error, msg} ->
        IO.err(ctx, "torrent: " <> msg)
        2

      %{sources: []} ->
        IO.err(ctx, "usage: torrent add [-d DIR] [--peer HOST:PORT] MAGNET|FILE|URL...")
        2

      o ->
        Enum.reduce(o.sources, 0, fn src, status ->
          case Lepton.Torrent.add(ctx, src, dir: o.dir, peers: o.peers) do
            {:ok, id} ->
              IO.puts(ctx, "Added #{Lepton.Torrent.short(id)}: downloading into #{Path.expand(o.dir || Path.join(Lepton.Ctx.home(ctx), "Downloads"), ctx.cwd)} (torrent shows its progress)")
              status

            {:error, why} ->
              IO.err(ctx, "torrent: " <> why)
              1
          end
        end)
    end
  end

  defp torrent(ctx, ["list"]) do
    case Lepton.Torrent.list(ctx) do
      [] ->
        IO.puts(ctx, "No torrents. (torrent add MAGNET|FILE adds one.)")

      list ->
        for {t, i} <- Enum.with_index(list, 1) do
          {name, detail} = Lepton.Torrent.CLI.describe(t)
          pct = if t.progress, do: "#{Float.round(min(t.progress, 1.0) * 100, 1)}%  ", else: ""
          IO.puts(ctx, "#{i}. #{name}  [#{Lepton.Torrent.short(t.id)}]\n   #{pct}#{detail}")
        end
    end

    0
  end

  defp torrent(ctx, [cmd, what]) when cmd in ["stop", "start"] do
    with {:ok, t} <- Lepton.Torrent.find(ctx, what),
         :ok <- if(cmd == "stop", do: Lepton.Torrent.stop(ctx, t.id), else: Lepton.Torrent.start(ctx, t.id)) do
      IO.puts(ctx, "#{if cmd == "stop", do: "Stopped", else: "Started"} #{t.name}.")
      0
    else
      {:error, why} -> IO.err(ctx, "torrent: " <> why); 1
    end
  end

  defp torrent(ctx, [rm | rest]) when rm in ["rm", "remove"] and rest != [] do
    {delete, names} = Enum.split_with(rest, &(&1 == "--delete"))

    Enum.reduce(names, 0, fn what, status ->
      case Lepton.Torrent.find(ctx, what) do
        {:ok, t} ->
          Lepton.Torrent.remove(ctx, t.id, delete: delete != [])
          IO.puts(ctx, "Removed #{t.name}" <> if(delete != [], do: " and its files.", else: " (its files stay in #{t.dir})."))
          status

        {:error, why} ->
          IO.err(ctx, "torrent: " <> why)
          1
      end
    end)
  end

  defp torrent(ctx, ["info", file]) do
    with {:ok, bin} <- File.read(Lepton.Ctx.path(ctx, file)),
         {:ok, m} <- Lepton.Torrent.Metainfo.parse(bin) do
      IO.puts(ctx, "#{m.name}\n  #{Lepton.Torrent.human(m.length)} in #{length(m.files)} file(s), #{Lepton.Torrent.Metainfo.piece_count(m)} pieces of #{Lepton.Torrent.human(m.piece_length)}")
      IO.puts(ctx, "  info hash #{Base.encode16(m.info_hash, case: :lower)}#{if m.private, do: " (private)", else: ""}")
      for t <- m.trackers, do: IO.puts(ctx, "  tracker #{t}")
      for {f, p} <- Enum.zip(m.files, Lepton.Torrent.Metainfo.paths(m, ".")) |> Enum.take(50), do: IO.puts(ctx, "  #{String.pad_leading(Lepton.Torrent.human(f.length), 9)}  #{Path.relative_to(p, ".")}")
      if length(m.files) > 50, do: IO.puts(ctx, "  ... and #{length(m.files) - 50} more")
      IO.puts(ctx, "  " <> Lepton.Torrent.Magnet.link(m.info_hash, m.name, m.trackers))
      0
    else
      {:error, why} when is_atom(why) -> IO.err(ctx, "torrent: #{file}: #{:file.format_error(why)}"); 1
      {:error, why} -> IO.err(ctx, "torrent: #{file}: #{why}"); 1
    end
  end

  defp torrent(ctx, ["create" | rest]) do
    {opts, paths} = create_opts(rest, %{out: nil, trackers: []}, [])

    case paths do
      [path] ->
        full = Lepton.Ctx.path(ctx, path)
        out = Lepton.Ctx.path(ctx, opts.out || Path.basename(full) <> ".torrent")

        case Lepton.Torrent.Metainfo.create(full, trackers: opts.trackers) do
          {:ok, bin} ->
            Lepton.Users.own_new(ctx, out, fn -> File.write!(out, bin) end)
            {:ok, m} = Lepton.Torrent.Metainfo.parse(bin)
            IO.puts(ctx, "Wrote #{out}: #{Lepton.Torrent.human(m.length)}, #{Lepton.Torrent.Metainfo.piece_count(m)} pieces.\n#{Lepton.Torrent.Magnet.link(m.info_hash, m.name, m.trackers)}")
            0

          {:error, why} ->
            IO.err(ctx, "torrent: " <> why)
            1
        end

      _ ->
        IO.err(ctx, "usage: torrent create [-o FILE] [-t TRACKER]... PATH")
        2
    end
  end

  defp torrent(ctx, _) do
    IO.err(ctx, "usage: torrent [add [-d DIR] MAGNET|FILE|URL | list | stop T | start T | rm [--delete] T | info FILE | create [-o FILE] [-t TRACKER]... PATH]")
    2
  end

  defp add_opts([d, dir | rest], o) when d in ["-d", "--dir"], do: add_opts(rest, %{o | dir: dir})

  defp add_opts([p, peer | rest], o) when p in ["-p", "--peer"] do
    case Regex.run(~r/^\[?([^\]]+?)\]?:(\d+)$/, peer, capture: :all_but_first) do
      [h, port] -> add_opts(rest, %{o | peers: o.peers ++ [{h, String.to_integer(port)}]})
      _ -> {:error, "--peer takes HOST:PORT"}
    end
  end

  defp add_opts(["-" <> _ = flag | _], _o) when flag not in ["-"], do: {:error, "unknown option #{flag}"}
  defp add_opts([src | rest], o), do: add_opts(rest, %{o | sources: o.sources ++ [src]})
  defp add_opts([], o), do: o

  defp create_opts([o, file | rest], opts, paths) when o in ["-o", "--output"], do: create_opts(rest, %{opts | out: file}, paths)
  defp create_opts([t, url | rest], opts, paths) when t in ["-t", "--tracker"], do: create_opts(rest, %{opts | trackers: opts.trackers ++ [url]}, paths)
  defp create_opts([p | rest], opts, paths), do: create_opts(rest, opts, paths ++ [p])
  defp create_opts([], opts, paths), do: {opts, paths}

  # FFmpeg there (true), or offered (in a terminal) and installed now.
  defp ensure_ffmpeg(ctx, what) do
    Lepton.FFmpeg.installed?() or Lepton.Apps.offer_install(ctx, "ffmpeg", what) == :installed
  end

  @doc false
  def clock(s), do: Player.clock(s)
end
