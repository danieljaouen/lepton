defmodule Lepton.Player do
  @moduledoc """
  Playing one file or stream: what `play` and `radio` (and their windows)
  drive.

  FFmpeg (`Lepton.FFmpeg`) decodes; the sound goes to the sound card
  through `Lepton.Sound` (so the system volume, `volume`, and the card it
  plays on apply), from a process of its own that counts what it has
  played: that is the position. Pictures, if there's a window
  (`Lepton.Player.Window`), come from a second ffmpeg the window runs.

  Pausing stops both and remembers the position; playing again starts
  them there (`-ss`), as seeking does. A stream (radio) has no position:
  pausing stops it, playing again picks it up live, and if it drops it is
  opened again (a few times). Radio streams are read by
  `Lepton.Radio.ICY`, which also reports each new song's title.

  Whoever starts it gets `{:player, pid, status}` messages as things
  change (`subscribe/1` adds others); `status/1` is the same map:
  `%{state: :playing | :paused | :ended | :error, position, duration,
  title, now_playing, live, video, error}`.
  """

  use GenServer, restart: :temporary

  alias Lepton.{FFmpeg, Sound}

  @rate 48_000
  @channels 2
  @bytes_per_second @rate * @channels * 2
  # a stream that drops is opened again this many times in a row
  @reconnects 5

  # -- API -----------------------------------------------------------------------------------------

  @doc """
  Play `url` (a path or address). Options: `:title`, `:live` (a stream:
  no position), `:icy` (read it as a radio stream), `:start` (seconds),
  `:window` (open a video window, if it has pictures: `env` with
  `WAYLAND_DISPLAY`), `:env`, `:info` (what ffprobe said, if known),
  `:paused`.
  """
  def start(url, opts \\ []), do: GenServer.start(__MODULE__, {url, opts, self()})

  def status(pid), do: GenServer.call(pid, :status)
  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})
  def toggle(pid), do: GenServer.cast(pid, :toggle)
  def pause(pid), do: GenServer.cast(pid, :pause)
  def resume(pid), do: GenServer.cast(pid, :resume)
  @doc "Seek by `delta` seconds (or to `{:to, seconds}`)."
  def seek(pid, delta), do: GenServer.cast(pid, {:seek, delta})
  def stop(pid), do: if(Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok)

  @doc "Position as `m:ss` (or `h:mm:ss`)."
  def clock(nil), do: "--:--"

  def clock(seconds) do
    s = trunc(seconds)
    {h, m, s} = {div(s, 3600), div(rem(s, 3600), 60), rem(s, 60)}
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    if h > 0, do: "#{h}:#{pad.(m)}:#{pad.(s)}", else: "#{m}:#{pad.(s)}"
  end

  # -- the server ----------------------------------------------------------------------------------

  @impl true
  def init({url, opts, owner}) do
    Process.flag(:trap_exit, true)
    info = opts[:info] || %{duration: nil, title: nil, artist: nil, video: nil, audio: true}
    live = opts[:live] || false

    st = %{
      url: url,
      info: info,
      live: live,
      icy: opts[:icy] || false,
      title: opts[:title] || display_title(info, url),
      # (a title given wins over the station's own name)
      named: opts[:title] != nil,
      now_playing: nil,
      station: nil,
      state: :paused,
      base: opts[:start] || 0.0,
      played: 0.0,
      audio: nil,
      window: nil,
      subs: MapSet.new([owner]),
      error: nil,
      sound_error: nil,
      reconnects: 0,
      # its window was closed: the video is over
      closed: false,
      env: opts[:env] || %{},
      # (ffmpeg runs as this user)
      user: opts[:user],
      log: log_path(opts[:env] || %{})
    }

    Process.monitor(owner)
    st = if opts[:window] && info.video, do: open_window(st, opts[:env]), else: st
    st = if opts[:paused], do: st, else: play(st)
    {:ok, st}
  end

  defp display_title(%{title: t, artist: a}, _url) when is_binary(t) and is_binary(a), do: "#{a} - #{t}"
  defp display_title(%{title: t}, _url) when is_binary(t), do: t
  defp display_title(_, url), do: if(url =~ ~r{^\w+://}, do: url, else: Path.basename(url))

  defp log_path(env) do
    home = env["HOME"] || "/root"
    Path.join([home, ".cache", "lepton", "ffmpeg.log"])
  end

  @impl true
  def handle_call(:status, _from, st), do: {:reply, view(st), st}
  def handle_call({:subscribe, pid}, _from, st), do: (Process.monitor(pid); {:reply, view(st), %{st | subs: MapSet.put(st.subs, pid)}})

  @impl true
  def handle_cast(:toggle, %{state: :playing} = st), do: {:noreply, st |> halt() |> Map.put(:state, :paused) |> notify()}
  def handle_cast(:toggle, st), do: {:noreply, st |> restart_if_ended() |> play()}
  def handle_cast(:pause, %{state: :playing} = st), do: {:noreply, st |> halt() |> Map.put(:state, :paused) |> notify()}
  def handle_cast(:pause, st), do: {:noreply, st}
  def handle_cast(:resume, %{state: :playing} = st), do: {:noreply, st}
  def handle_cast(:resume, st), do: {:noreply, st |> restart_if_ended() |> play()}
  def handle_cast({:seek, _}, %{live: true} = st), do: {:noreply, st}

  def handle_cast({:seek, delta}, st) do
    now = position(st)
    target = case delta do
      {:to, t} -> t
      d -> now + d
    end

    target = target |> max(0.0) |> then(&if(st.info.duration, do: min(&1, max(st.info.duration - 1, 0.0)), else: &1))
    playing? = st.state in [:playing, :ended]
    st = %{halt(st) | base: target, played: 0.0}
    {:noreply, if(playing?, do: play(st), else: notify(st))}
  end

  @impl true
  def handle_info({:played, pid, seconds}, %{audio: pid} = st), do: {:noreply, notify(%{st | played: seconds, reconnects: 0})}

  def handle_info({:icy, {:title, t}}, st), do: {:noreply, notify(%{st | now_playing: t})}
  def handle_info({:icy, {:name, n}}, st), do: {:noreply, notify(%{st | station: n})}
  def handle_info({:sound_error, pid, why}, %{audio: pid} = st), do: {:noreply, notify(%{st | sound_error: why})}

  # An HLS stream (a playlist of pieces): ffmpeg reads it from its address.
  def handle_info({:audio_done, pid, {:hls, url}}, %{audio: pid} = st), do: {:noreply, start_audio(%{st | audio: nil, url: url, icy: false})}

  # The sound ended: the end of the file, or a stream that dropped.
  def handle_info({:audio_done, pid, result}, %{audio: pid} = st) do
    st = %{st | audio: nil}

    cond do
      st.live and st.reconnects < @reconnects and st.state == :playing ->
        Process.send_after(self(), :reconnect, 1000 * (st.reconnects + 1))
        {:noreply, notify(%{st | reconnects: st.reconnects + 1, error: "reconnecting..."})}

      match?({:error, _}, result) ->
        {:noreply, st |> halt() |> Map.merge(%{state: :error, error: elem(result, 1)}) |> notify()}

      true ->
        {:noreply, st |> halt() |> Map.put(:state, :ended) |> notify()}
    end
  end

  def handle_info(:reconnect, %{state: :playing, audio: nil} = st), do: {:noreply, start_audio(%{st | error: nil})}
  def handle_info(:reconnect, st), do: {:noreply, st}

  # The window closed (its close button, q): this video is over; its sound
  # stops too, and whoever plays a list goes on to the next.
  def handle_info({:window_closed, pid}, %{window: pid} = st), do: {:noreply, window_gone(st)}

  def handle_info({:DOWN, _, :process, pid, _}, st) do
    subs = MapSet.delete(st.subs, pid)
    # (nobody listening, and no window: nothing to play for)
    if MapSet.size(subs) == 0 and st.window == nil, do: {:stop, :normal, %{st | subs: subs}}, else: {:noreply, %{st | subs: subs}}
  end

  def handle_info({:EXIT, pid, _}, %{audio: pid} = st), do: {:noreply, %{st | audio: nil}}
  def handle_info({:EXIT, pid, _}, %{window: pid} = st), do: {:noreply, window_gone(st)}
  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    halt(st)
    # (asked to close: it closes its connection, and leaves the screen)
    if st.window && Process.alive?(st.window) do
      try do
        GenServer.stop(st.window, :normal, 2000)
      catch
        :exit, _ -> Process.exit(st.window, :kill)
      end
    end

    :ok
  end

  defp window_gone(st) do
    st = if st.state == :playing, do: st |> halt() |> Map.put(:state, :ended), else: st
    notify(%{st | window: nil, closed: true})
  end

  # -- playing -------------------------------------------------------------------------------------

  defp restart_if_ended(%{state: :ended} = st), do: %{st | base: 0.0, played: 0.0}
  defp restart_if_ended(st), do: st

  defp play(st) do
    case FFmpeg.missing() do
      nil -> %{st | state: :playing, error: nil} |> start_audio() |> start_video() |> notify()
      why -> notify(%{st | state: :error, error: why})
    end
  end

  # Stop the sound and the pictures, keeping the position.
  defp halt(st) do
    if st.audio, do: (Process.unlink(st.audio); Process.exit(st.audio, :kill))
    if st.window, do: send(st.window, :stop_video)
    %{st | audio: nil, base: position(st), played: 0.0}
  end

  defp position(%{live: true}), do: nil
  defp position(st), do: st.base + st.played

  defp start_audio(%{info: %{audio: false}} = st), do: st

  defp start_audio(st) do
    me = self()
    url = st.url
    opts = [start: st.base, live: st.live, rate: @rate, channels: @channels, user: st.user]
    {icy, env, log} = {st.icy, st.env, st.log}
    # (the log's folder the user's, for ffmpeg running as them to write in)
    Lepton.Users.own_new_in_home(Path.dirname(log), fn -> File.mkdir_p(Path.dirname(log)) end)
    pid = spawn_link(fn -> run_audio(me, url, opts, icy, env, log) end)
    %{st | audio: pid}
  end

  defp start_video(%{window: nil} = st), do: st

  defp start_video(st) do
    send(st.window, {:start_video, st.url, st.base, st.live})
    st
  end

  defp open_window(st, env) do
    case Lepton.Player.Window.start(player: self(), env: env, title: st.title, video: st.info.video, user: st.user) do
      {:ok, pid} -> Process.link(pid); %{st | window: pid}
      {:error, why} -> %{st | error: "no window: #{inspect(why)}"}
    end
  end

  # The process that plays the sound: ffmpeg's samples to the card,
  # reporting what has been played (a few times a second).
  @doc false
  def run_audio(player, url, opts, icy, env, log) do
    {input, feeder} = if icy, do: {"pipe:0", url}, else: {url, nil}
    port = FFmpeg.open("ffmpeg", FFmpeg.audio_args(input, opts), log: log, user: opts[:user])

    if feeder do
      me = self()

      spawn_link(fn ->
        result = Lepton.Radio.ICY.run(feeder, &Port.command(port, &1), &send(player, {:icy, &1}), env)

        case result do
          # HLS: ffmpeg reads it itself (this ffmpeg reads stdin: start one that doesn't)
          {:hls, u} -> send(me, {:hls, u})
          {:error, why} -> send(me, {:feed_error, why})
          _ -> send(me, {:feed_done})
        end
      end)
    end

    chunks = samples(port, player)

    result =
      case Sound.play(chunks, @rate, @channels) do
        :ok -> :ok
        {:error, why} ->
          # No sound (no card, or the card is busy): the pictures still play,
          # at the file's pace.
          send(player, {:sound_error, self(), why})
          Stream.run(chunks)
          :ok
      end

    final = Process.get(:result) || result
    send(player, {:audio_done, self(), final})
  end

  defp samples(port, player) do
    Stream.resource(
      fn -> {0, System.monotonic_time(:millisecond)} end,
      fn
        :halt ->
          {:halt, :halt}

        {bytes, last} ->
          receive do
            {^port, {:data, d}} ->
              bytes = bytes + byte_size(d)
              now = System.monotonic_time(:millisecond)

              if now - last >= 250 do
                send(player, {:played, self(), bytes / @bytes_per_second})
                {[d], {bytes, now}}
              else
                {[d], {bytes, last}}
              end

            {^port, {:exit_status, 0}} ->
              send(player, {:played, self(), bytes / @bytes_per_second})
              {:halt, :halt}

            {^port, {:exit_status, n}} ->
              Process.put(:result, {:error, "ffmpeg stopped (#{n}): see ~/.cache/lepton/ffmpeg.log"})
              {:halt, :halt}

            {:feed_error, why} ->
              Process.put(:result, {:error, why})
              {:halt, :halt}

            {:hls, u} ->
              Process.put(:result, {:hls, u})
              {:halt, :halt}

            {:feed_done} ->
              Port.close(port)
              {:halt, :halt}
          end
      end,
      fn _ -> :ok end
    )
  end

  # -- status --------------------------------------------------------------------------------------

  defp view(st) do
    %{
      state: st.state,
      position: position(st),
      duration: st.info.duration,
      title: if(st.named, do: st.title, else: st.station || st.title),
      now_playing: st.now_playing,
      live: st.live,
      video: st.info.video != nil,
      window: st.window != nil,
      closed: st.closed,
      error: st.error || st.sound_error,
      url: st.url
    }
  end

  defp notify(st) do
    v = view(st)
    for pid <- st.subs, do: send(pid, {:player, self(), v})
    if st.window, do: send(st.window, {:player, self(), v})
    st
  end
end
