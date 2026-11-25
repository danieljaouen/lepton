defmodule Lepton.FFmpeg do
  @moduledoc """
  FFmpeg, the `ffmpeg` app (`sudo app install ffmpeg`): `ffmpeg` decodes
  files and streams into what Lepton plays and draws (16-bit samples,
  `bgr0` pixels, on standard output), and `ffprobe` says what a file
  holds. The media player (`Lepton.Player`) and the radio run them.
  """

  alias Lepton.Apps

  @app "ffmpeg"

  # (`config :lepton, ffmpeg_prefix: DIR`: an unpacked copy elsewhere, for development)
  defp prefix, do: Application.get_env(:lepton, :ffmpeg_prefix) || Apps.dir(@app)

  def installed?, do: if(Application.get_env(:lepton, :ffmpeg_prefix), do: File.exists?(program("ffmpeg")), else: Apps.installed?(@app))

  @doc "Why it can't run, or nil."
  def missing do
    if installed?(), do: nil, else: "FFmpeg isn't installed. Install it with: sudo app install ffmpeg"
  end

  @doc "A program of the app (`ffmpeg`, `ffprobe`)."
  def program(name), do: Path.join([prefix(), "usr/bin", name])

  @doc """
  The environment its programs run with: their libraries (PulseAudio's
  own library, which libpulse links, lives in a folder of its own).
  """
  def env do
    %{"LD_LIBRARY_PATH" => Enum.map_join(["usr/lib", "lib", "usr/lib/pulseaudio"], ":", &Path.join(prefix(), &1))}
  end

  @doc """
  Start `name` (`"ffmpeg"`) with `args` as a port: its standard output
  comes as `{port, {:data, binary}}` messages, its exit as
  `{port, {:exit_status, n}}`. Standard error goes to `log` (a path), or
  is dropped. It runs as `:user` (a name; else root): a file or a stream
  from anywhere is decoded with that user's rights, not Lepton's.
  """
  def open(name, args, opts \\ []) do
    err = opts[:log] || "/dev/null"
    # (stderr to a file: sh, so that it doesn't mix with the samples)
    script = ~S'exec "$0" "$@" 2>>"$LEPTON_FFMPEG_LOG"'
    sh = if File.exists?("/bin/sh"), do: "/bin/sh", else: System.find_executable("sh")
    env = Map.merge(env(), %{"LEPTON_FFMPEG_LOG" => err})

    {exe, argv} = as_user(opts[:user], sh, ["-c", script, program(name) | args])

    Port.open({:spawn_executable, exe}, [
      :binary,
      :exit_status,
      :use_stdio,
      args: argv,
      env: Enum.map(env, fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)
    ])
  end

  @doc """
  What a file or address holds: `%{duration: seconds | nil, title, artist,
  album, video: %{w, h, fps} | nil, audio: bool}`, from ffprobe.
  """
  def probe(url, user \\ nil) do
    args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url]
    {exe, argv} = as_user(user, program("ffprobe"), args)

    case System.cmd(exe, argv, env: Enum.to_list(env()), stderr_to_stdout: true) do
      {out, 0} ->
        # (the JSON, after any warning)
        {:ok, out |> binary_part_from("{") |> JSON.decode!() |> parse_probe()}

      {out, _} ->
        why = out |> String.split("\n") |> Enum.reject(&(String.trim(&1) in ["", "{", "}"])) |> Enum.map_join("; ", &String.replace(&1, url <> ": ", ""))
        {:error, if(why == "", do: "can't read #{url}", else: "#{url}: #{why}")}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp as_user(nil, exe, args), do: {exe, args}

  defp as_user(name, exe, args) do
    case Lepton.Users.get(name) do
      nil -> {exe, args}
      user -> Lepton.RunAs.command(user, exe, args)
    end
  end

  defp binary_part_from(text, mark) do
    case :binary.match(text, mark) do
      {at, _} -> binary_part(text, at, byte_size(text) - at)
      :nomatch -> text
    end
  end

  @doc false
  def parse_probe(json) do
    format = json["format"] || %{}
    tags = Map.new(format["tags"] || %{}, fn {k, v} -> {String.downcase(k), v} end)
    streams = json["streams"] || []
    # (a cover picture in an MP3 is a "video" stream: attached_pic)
    video = Enum.find(streams, &(&1["codec_type"] == "video" and get_in(&1, ["disposition", "attached_pic"]) != 1))

    %{
      duration: number(format["duration"]),
      title: tags["title"],
      artist: tags["artist"],
      album: tags["album"],
      audio: Enum.any?(streams, &(&1["codec_type"] == "audio")),
      video: video && %{w: video["width"], h: video["height"], fps: rate(video["avg_frame_rate"]) || rate(video["r_frame_rate"]) || 25.0}
    }
  end

  defp number(nil), do: nil
  defp number(s) when is_binary(s), do: (case Float.parse(s) do
    {f, _} when f > 0 -> f
    _ -> nil
  end)
  defp number(n) when is_number(n), do: n * 1.0

  defp rate(nil), do: nil

  defp rate(s) do
    case String.split(s, "/") do
      [a, b] -> with {a, ""} <- Integer.parse(a), {b, ""} <- Integer.parse(b), true <- b > 0 and a > 0, do: a / b, else: (_ -> nil)
      _ -> nil
    end
  end

  @doc """
  ffmpeg's arguments for the sound of `url` from `start` seconds, as
  16-bit samples at `rate` with `channels` on standard output. A file is
  read at its own pace (`-re`): ports don't hold back, so decoding ahead
  would pile the whole file up in memory.
  """
  def audio_args(url, opts \\ []) do
    input(url, opts) ++ ["-vn", "-sn", "-f", "s16le", "-ar", "#{opts[:rate] || 48_000}", "-ac", "#{opts[:channels] || 2}", "pipe:1"]
  end

  @doc "ffmpeg's arguments for the pictures, `bgr0` frames of `w`x`h` (the picture fitted, black around it)."
  def video_args(url, w, h, opts \\ []) do
    fit = "scale=#{w}:#{h}:force_original_aspect_ratio=decrease,pad=#{w}:#{h}:(ow-iw)/2:(oh-ih)/2,format=bgr0"
    input(url, opts) ++ ["-an", "-sn", "-vf", fit, "-f", "rawvideo", "pipe:1"]
  end

  defp input(url, opts) do
    start = opts[:start] || 0
    seek = if start > 0, do: ["-ss", :erlang.float_to_binary(start * 1.0, decimals: 3)], else: []
    pace = if opts[:live], do: [], else: ["-re"]
    stdin = if url == "pipe:0", do: [], else: ["-nostdin"]
    ["-hide_banner", "-loglevel", "error"] ++ stdin ++ pace ++ seek ++ ["-i", url]
  end
end
