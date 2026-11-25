defmodule Lepton.Torrent do
  @moduledoc """
  BitTorrent (`torrent`): downloading what a `.torrent` file or a magnet
  link describes, and sharing it back (seeding) while it stays added.

  Each torrent is a `Lepton.Torrent.Session`, running in Lepton itself:
  a download goes on after the command that added it ends, and after
  you log out. Each one is recorded in your
  `~/.local/state/lepton/torrents/` (its `.torrent`, or its magnet link
  until the files' list arrives, and a few facts: the folder, whether
  it runs), so `torrent` lists yours, and the ones that were running
  start again the next time you use `torrent` (after a restart, say).
  """

  alias Lepton.Torrent.{Magnet, Metainfo, Session}

  @version "0127"

  @doc "A peer id: Lepton's prefix (Azureus style) and random bytes."
  def peer_id, do: "-LP#{@version}-" <> :crypto.strong_rand_bytes(12)

  def records_dir(home), do: Path.join(home, ".local/state/lepton/torrents")

  # -- adding ------------------------------------------------------------------------------------

  @doc """
  Add a torrent: `source` is a `.torrent` file, a magnet link, or the
  address of a `.torrent`. Options: `:dir` (where the files go; default
  `~/Downloads`), `:peers` (`[{host, port}]` to try besides those found).
  Returns `{:ok, id}`.
  """
  def add(ctx, source, opts \\ []) do
    home = Lepton.Ctx.home(ctx)
    dir = Path.expand(opts[:dir] || Path.join(home, "Downloads"), ctx.cwd || home)

    with {:ok, what} <- read_source(ctx, source) do
      hash = info_hash(what)
      id = Base.encode16(hash, case: :lower)

      if Session.whereis(hash) do
        {:error, "that torrent is already added (#{short(id)})"}
      else
        Lepton.Users.own_new_in_home(dir, fn -> File.mkdir_p(dir) end)
        record = %{"id" => id, "dir" => dir, "state" => "running", "added" => System.os_time(:second), "name" => name(what)}
        write_record(home, record, what)

        case start_session(home, record, what, opts[:peers] || []) do
          {:ok, _} -> {:ok, id}
          err -> err
        end
      end
    end
  end

  defp info_hash(%Metainfo{info_hash: h}), do: h
  defp info_hash(%Magnet{info_hash: h}), do: h
  defp name(%Metainfo{name: n}), do: n
  defp name(%Magnet{name: n}), do: n

  defp read_source(ctx, source) do
    cond do
      Magnet.magnet?(source) ->
        Magnet.parse(source)

      source =~ ~r{^https?://}i ->
        case Lepton.Alpine.get(source) do
          {:ok, body} -> Metainfo.parse(body)
          {:error, why} -> {:error, "couldn't fetch #{source}: #{inspect(why)}"}
        end

      true ->
        path = Lepton.Ctx.path(ctx, source)

        case File.read(path) do
          {:ok, bin} -> Metainfo.parse(bin)
          {:error, why} -> {:error, "#{source}: #{:file.format_error(why)}"}
        end
    end
  end

  defp start_session(home, record, what, peers) do
    Lepton.Torrent.Listener.ensure_started()

    {meta, magnet} =
      case what do
        %Metainfo{} = m -> {m, nil}
        %Magnet{} = m -> {nil, m}
      end

    opts = [
      info_hash: info_hash(what),
      meta: meta,
      name: record["name"],
      trackers: (magnet && magnet.trackers) || [],
      peers: ((magnet && magnet.peers) || []) ++ peers,
      dir: record["dir"],
      home: home,
      dht: Application.get_env(:lepton, :torrent_dht, true)
    ]

    case DynamicSupervisor.start_child(Lepton.Torrent.Supervisor, {Session, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  # -- records -------------------------------------------------------------------------------------

  defp write_record(home, record, what) do
    dir = records_dir(home)
    id = record["id"]

    Lepton.Users.own_new_in_home(dir, fn ->
      File.mkdir_p(dir)

      case what do
        %Metainfo{} = m -> File.write(Path.join(dir, id <> ".torrent"), torrent_file(m))
        %Magnet{} = m -> File.write(Path.join(dir, id <> ".magnet"), Magnet.link(m.info_hash, m.name, m.trackers) <> "\n")
        nil -> :ok
      end

      File.write(Path.join(dir, id <> ".json"), JSON.encode!(record))
    end)
  end

  defp torrent_file(%Metainfo{} = m) do
    trackers = m.trackers

    extra =
      case trackers do
        [] -> ""
        [one] -> Lepton.Torrent.Bencode.encode("announce") <> Lepton.Torrent.Bencode.encode(one)
        list -> Lepton.Torrent.Bencode.encode("announce") <> Lepton.Torrent.Bencode.encode(hd(list)) <> Lepton.Torrent.Bencode.encode("announce-list") <> Lepton.Torrent.Bencode.encode(Enum.map(list, &[&1]))
      end

    # (the info dictionary's own bytes, so the hash stays the same)
    "d" <> extra <> Lepton.Torrent.Bencode.encode("info") <> m.info <> "e"
  end

  @doc false
  # From a session: its files' list arrived, it finished, or it was checked.
  def save_record(st) do
    home = st[:home]

    if home do
      id = Base.encode16(st.info_hash, case: :lower)
      record = read_record(home, id) || %{"id" => id, "dir" => st.dir, "added" => System.os_time(:second)}
      record = Map.merge(record, %{"name" => st.name, "state" => if(record["state"] == "stopped", do: "stopped", else: "running")})
      if st.meta, do: File.rm(Path.join(records_dir(home), id <> ".magnet"))
      write_record(home, record, st.meta)
    end

    :ok
  end

  defp read_record(home, id) do
    with {:ok, text} <- File.read(Path.join(records_dir(home), id <> ".json")),
         {:ok, r} <- JSON.decode(text) do
      r
    else
      _ -> nil
    end
  end

  defp records(home) do
    dir = records_dir(home)

    for f <- Path.wildcard(Path.join(dir, "*.json")), r = read_record(home, Path.basename(f, ".json")), do: r
  end

  defp source_of(home, id) do
    dir = records_dir(home)

    cond do
      File.exists?(Path.join(dir, id <> ".torrent")) -> Metainfo.parse(File.read!(Path.join(dir, id <> ".torrent")))
      File.exists?(Path.join(dir, id <> ".magnet")) -> Magnet.parse(String.trim(File.read!(Path.join(dir, id <> ".magnet"))))
      true -> {:error, "its record is incomplete"}
    end
  end

  # -- listing and changing ------------------------------------------------------------------------

  @doc """
  Your torrents, oldest first: the running ones' status
  (`Lepton.Torrent.Session`'s), the stopped ones' name and folder. Those
  recorded as running that aren't (Lepton restarted) start again.
  """
  def list(ctx) do
    home = Lepton.Ctx.home(ctx)

    records(home)
    |> Enum.sort_by(& &1["added"])
    |> Enum.map(fn r ->
      hash = Base.decode16!(r["id"], case: :lower)
      pid = Session.whereis(hash)

      pid =
        if pid == nil and r["state"] == "running" do
          case source_of(home, r["id"]) do
            {:ok, what} -> case start_session(home, r, what, []) do
                {:ok, p} -> p
                _ -> nil
              end
            _ -> nil
          end
        else
          pid
        end

      if pid do
        try do
          Session.status(pid)
        catch
          :exit, _ -> stopped(r)
        end
      else
        stopped(r)
      end
    end)
  end

  defp stopped(r), do: %{id: r["id"], name: r["name"] || r["id"], state: :stopped, dir: r["dir"], size: nil, done: 0, progress: nil, peers: 0, connecting: 0, down_rate: 0.0, up_rate: 0.0, eta: nil, error: nil}

  def short(id), do: String.slice(id, 0, 8)

  @doc "The torrent `what` names: its number in the list (1, 2, ...), the start of its id, or part of its name."
  def find(ctx, what) do
    list = list(ctx)

    found =
      case Integer.parse(what) do
        {n, ""} when n >= 1 and n <= length(list) -> [Enum.at(list, n - 1)]
        _ ->
          by_id = Enum.filter(list, &String.starts_with?(&1.id, String.downcase(what)))
          if by_id != [], do: by_id, else: Enum.filter(list, &String.contains?(String.downcase(&1.name || ""), String.downcase(what)))
      end

    case found do
      [t] -> {:ok, t}
      [] -> {:error, "no torrent \"#{what}\" (torrent list shows them)"}
      _ -> {:error, "\"#{what}\" means more than one torrent: use its number or id"}
    end
  end

  @doc "Stop one (it stays listed; `start/2` resumes it)."
  def stop(ctx, id) do
    home = Lepton.Ctx.home(ctx)
    halt(id)
    if r = read_record(home, id), do: write_record(home, Map.put(r, "state", "stopped"), nil)
    :ok
  end

  def start(ctx, id) do
    home = Lepton.Ctx.home(ctx)

    with r when r != nil <- read_record(home, id) || {:error, "no record of #{id}"},
         {:ok, what} <- source_of(home, id),
         {:ok, _} <- start_session(home, Map.put(r, "state", "running"), what, []) do
      write_record(home, Map.put(r, "state", "running"), nil)
      :ok
    end
  end

  @doc "Remove one: stopped, its record gone; with `delete: true`, its files too."
  def remove(ctx, id, opts \\ []) do
    home = Lepton.Ctx.home(ctx)
    src = source_of(home, id)
    r = read_record(home, id)
    halt(id)
    for ext <- [".json", ".torrent", ".magnet"], do: File.rm(Path.join(records_dir(home), id <> ext))

    if opts[:delete] && r do
      case src do
        {:ok, %Metainfo{} = m} ->
          # (one file, or the torrent's folder)
          File.rm_rf(Path.join(r["dir"], m.name))

        _ ->
          :ok
      end
    end

    :ok
  end

  defp halt(id) do
    case Session.whereis(Base.decode16!(id, case: :lower)) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(Lepton.Torrent.Supervisor, pid)
    end
  end

  # -- figures ---------------------------------------------------------------------------------------

  def human(nil), do: "?"
  def human(n) when n < 1024, do: "#{round(n)} B"
  def human(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  def human(n) when n < 1024 * 1024 * 1024, do: "#{Float.round(n / 1024 / 1024, 1)} MB"
  def human(n), do: "#{Float.round(n / 1024 / 1024 / 1024, 2)} GB"

  def eta(nil), do: ""
  def eta(s) when s < 60, do: "#{s}s"
  def eta(s) when s < 3600, do: "#{div(s, 60)}m"
  def eta(s), do: "#{div(s, 3600)}h#{div(rem(s, 3600), 60)}m"
end
