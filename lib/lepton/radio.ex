defmodule Lepton.Radio do
  @moduledoc """
  Internet radio (`radio`): your stations, a search of Radio Browser's
  directory (radio-browser.info, some 50,000 stations), and playing one
  with `Lepton.Player` (streams read by `Lepton.Radio.ICY`, so each
  song's title shows as it starts).

  Your stations are kept in `~/.config/lepton/radio`, one a line, a name
  and an address with a tab between them; until you add one, a few
  listener-supported stations are offered.
  """

  alias Lepton.{Player, Sound, TTY}

  @defaults [
    {"SomaFM Groove Salad", "https://ice2.somafm.com/groovesalad-128-mp3"},
    {"SomaFM Drone Zone", "https://ice2.somafm.com/dronezone-128-mp3"},
    {"Radio Paradise", "https://stream.radioparadise.com/mp3-192"},
    {"KEXP Seattle", "https://kexp.streamguys1.com/kexp160.aac"},
    {"FIP (Radio France)", "https://icecast.radiofrance.fr/fip-hifi.aac"}
  ]

  @servers ["de1.api.radio-browser.info", "fi1.api.radio-browser.info", "de2.api.radio-browser.info"]

  # -- your stations ---------------------------------------------------------------------------

  def file(ctx), do: Path.join(Lepton.Ctx.home(ctx), ".config/lepton/radio")

  @doc "Your stations, `[{name, url}]` (the defaults until you have a file)."
  def stations(ctx) do
    case File.read(file(ctx)) do
      {:ok, text} -> parse(text)
      _ -> @defaults
    end
  end

  def defaults, do: @defaults

  @doc false
  def parse(text) do
    for line <- String.split(text, "\n"),
        line = String.trim(line),
        line != "" and not String.starts_with?(line, "#"),
        [name, url] <- [String.split(line, "\t", parts: 2)],
        do: {String.trim(name), String.trim(url)}
  end

  def save(ctx, stations) do
    path = file(ctx)
    text = "# radio stations: a name, a tab, an address\n" <> Enum.map_join(stations, "", fn {n, u} -> "#{clean(n)}\t#{u}\n" end)

    Lepton.Users.own_new_in_home(path, fn ->
      File.mkdir_p(Path.dirname(path))
      File.write(path, text)
    end)
  end

  defp clean(name), do: name |> String.replace(~r/[\t\r\n]+/, " ") |> String.trim()

  @doc "Add (or rename, for an address you have) a station."
  def add(ctx, name, url) do
    list = stations(ctx) |> Enum.reject(fn {n, u} -> u == url or String.downcase(n) == String.downcase(name) end)
    save(ctx, list ++ [{clean(name), url}])
  end

  @doc "Remove the station called `name` (or at `url`): `:ok` or `{:error, :none}`."
  def remove(ctx, name) do
    list = stations(ctx)
    left = Enum.reject(list, fn {n, u} -> String.downcase(n) == String.downcase(name) or u == name end)
    if length(left) == length(list), do: {:error, :none}, else: save(ctx, left)
  end

  @doc "The station a name (or the start of one) or an address means."
  def find(ctx, query) do
    if query =~ ~r{^https?://}i do
      {:ok, {query, query}}
    else
      list = stations(ctx)
      q = String.downcase(query)

      case Enum.find(list, fn {n, _} -> String.downcase(n) == q end) ||
             Enum.find(list, fn {n, _} -> String.starts_with?(String.downcase(n), q) end) ||
             Enum.find(list, fn {n, _} -> String.contains?(String.downcase(n), q) end) do
        nil -> {:error, "no station called \"#{query}\" (radio list shows yours; radio search finds others)"}
        s -> {:ok, s}
      end
    end
  end

  # -- Radio Browser -----------------------------------------------------------------------------

  @doc """
  Stations matching `words` in Radio Browser's directory (by name, then by
  tag): `{:ok, [%{name, url, country, codec, bitrate, tags}]}`, the most
  listened to first.
  """
  def search(words, opts \\ []) do
    q = URI.encode_www_form(String.trim(words))
    limit = opts[:limit] || 40
    common = "&limit=#{limit}&hidebroken=true&order=clickcount&reverse=true"

    with {:ok, by_name} <- query("/json/stations/search?name=#{q}" <> common),
         {:ok, by_tag} <- if(length(by_name) < 10, do: query("/json/stations/search?tag=#{q}" <> common), else: {:ok, []}) do
      {:ok, (by_name ++ by_tag) |> Enum.uniq_by(& &1.url) |> Enum.take(limit)}
    end
  end

  defp query(path) do
    Enum.reduce_while(@servers, {:error, "Radio Browser didn't answer"}, fn server, err ->
      case Lepton.Alpine.get("https://" <> server <> path) do
        {:ok, body} -> {:halt, {:ok, results(body)}}
        _ -> {:cont, err}
      end
    end)
  end

  @doc false
  def results(body) do
    for s <- JSON.decode!(body), url = s["url_resolved"] || s["url"], url not in [nil, ""] do
      %{
        name: String.trim(s["name"] || url),
        url: url,
        country: s["countrycode"] || s["country"] || "",
        codec: s["codec"] || "",
        bitrate: s["bitrate"] || 0,
        tags: s["tags"] || ""
      }
    end
  end

  # -- playing ---------------------------------------------------------------------------------

  @doc "Play a station (in a terminal: until `q`, with its titles as they change)."
  def play(ctx, {name, url}), do: Lepton.Player.CLI.run(ctx, [url], icy: true, titles: [name], video: false)

  # -- the full-screen radio ------------------------------------------------------------------------

  @doc """
  `radio` in a terminal (the desktop's Radio): your stations, a search
  (`/`), the station playing and its song. Enter plays, Space stops or
  starts again, `a` adds a found station to yours, `d` removes one of
  yours, Tab switches between yours and what was found, `9`/`0` the
  volume, `q` quits. A click selects a station, a double click plays it,
  the wheel moves, and a click on a tab shows it.
  """
  def ui(ctx) do
    tty = ctx.tty
    TTY.set_mode(tty, :raw)
    TTY.write(tty, "\e[?1049h\e[?25l" <> Lepton.ListMouse.on())

    st = %{view: :mine, mine: stations(ctx), found: [], sel: 0, top: 0, player: nil, playing: nil, status: nil, message: nil, search: nil}

    try do
      ui_loop(ctx, tty, st)
    after
      TTY.write(tty, Lepton.ListMouse.off() <> "\e[0m\e[?25h\e[?1049l")
      TTY.set_mode(tty, :cooked)
    end
  end

  defp ui_loop(ctx, tty, st) do
    size = TTY.size(tty)
    st = st |> drain() |> expire(System.monotonic_time(:millisecond)) |> Map.put(:size, size)
    st = %{st | top: list_top(st, size)}
    TTY.write(tty, ["\e[H\e[2J", Enum.join(screen(st, size), "\r\n")])

    case TTY.read_key(tty, 500) do
      :timeout -> ui_loop(ctx, tty, st)
      key ->
        case ui_key(ctx, st, key) do
          {:quit, st} -> if st.player, do: Player.stop(st.player); 0
          st -> ui_loop(ctx, tty, st)
        end
    end
  end

  defp drain(%{player: p} = st) when p != nil do
    receive do
      {:player, ^p, s} -> drain(%{st | status: s})
    after
      0 -> st
    end
  end

  defp drain(st), do: st

  # A message (added, removed, found, an error) shows for a few seconds,
  # then the keys come back. (`shown`: the message on screen and since when.)
  @message_ms 4000

  @doc false
  def expire(%{message: nil} = st, _now), do: Map.put(st, :shown, nil)

  def expire(%{message: m} = st, now) do
    case Map.get(st, :shown) do
      {^m, t} when now - t >= @message_ms -> %{st | message: nil} |> Map.put(:shown, nil)
      {^m, _} -> st
      _ -> Map.put(st, :shown, {m, now})
    end
  end

  defp list(st), do: if(st.view == :mine, do: Enum.map(st.mine, fn {n, u} -> %{name: n, url: u, country: "", codec: "", bitrate: 0, tags: ""} end), else: st.found)

  @doc false
  def ui_key(_ctx, %{search: q} = st, key) when is_binary(q) do
    case key do
      "RET" ->
        st = %{st | search: nil, message: "Searching Radio Browser for \"#{q}\"..."}

        case search(q) do
          {:ok, []} -> %{st | message: "Nothing found for \"#{q}\""}
          {:ok, found} -> %{st | found: found, view: :found, sel: 0, top: 0, message: "#{length(found)} stations for \"#{q}\": Enter plays, a adds to yours"}
          {:error, why} -> %{st | message: why}
        end

      k when k in ["ESC", "C-g"] -> %{st | search: nil, message: nil}
      "DEL" -> %{st | search: String.slice(q, 0..-2//1)}
      " " -> %{st | search: q <> " "}
      "SPC" -> %{st | search: q <> " "}
      k when is_binary(k) -> if String.length(k) == 1, do: %{st | search: q <> k}, else: st
      _ -> st
    end
  end

  def ui_key(ctx, st, key) do
    items = list(st)
    n = length(items)

    case key do
      k when k in ["q", "C-c"] -> {:quit, st}
      k when k in ["<down>", "j", "C-n"] -> %{st | sel: min(st.sel + 1, max(n - 1, 0))}
      k when k in ["<up>", "k", "C-p"] -> %{st | sel: max(st.sel - 1, 0)}
      "/" -> %{st | search: ""}
      "TAB" -> %{st | view: if(st.view == :mine, do: :found, else: :mine), sel: 0, top: 0}
      "RET" when n > 0 -> start(ctx, st, Enum.at(items, st.sel))
      k when k in [" ", "SPC", "s"] -> toggle(ctx, st)
      k when k in ["0", "+", "="] -> Sound.change(5); st
      k when k in ["9", "-"] -> Sound.change(-5); st
      "m" -> Sound.mute(:toggle); st
      {:mouse, _, _, _, _, _} = m -> mouse(ctx, st, m, items)
      "a" when st.view == :found and n > 0 ->
        s = Enum.at(items, st.sel)
        add(ctx, s.name, s.url)
        %{st | mine: stations(ctx), message: "Added #{s.name} to your stations"} |> Map.put(:shown, nil)

      "d" when st.view == :mine and n > 0 ->
        s = Enum.at(items, st.sel)
        remove(ctx, s.name)
        # (removing the last of the defaults leaves the file, empty: no defaults again)
        if stations(ctx) == @defaults and not File.exists?(file(ctx)), do: save(ctx, [])
        mine = stations(ctx)
        %{st | mine: mine, sel: min(st.sel, max(length(mine) - 1, 0)), message: "Removed #{s.name}"} |> Map.put(:shown, nil)

      _ -> st
    end
  end

  # The list's lines start on row 2, under the tabs; rows 3 to 7 from the bottom are the rest.
  defp list_height({rows, _}), do: max(rows - 7, 1)
  defp list_top(st, size), do: Lepton.ListMouse.top(st.sel, st.top, list_height(size))

  # The tabs on row 0: " Radio  " then " Your stations " and " Found ".
  @tab_mine 8..22
  @tab_found 24..30

  defp mouse(ctx, st, {:mouse, :press, :left, x, 0, _}, _items) do
    cond do
      x in @tab_mine and st.view != :mine -> %{st | view: :mine, sel: 0, top: 0}
      x in @tab_found and st.view != :found -> %{st | view: :found, sel: 0, top: 0}
      true -> _ = ctx; st
    end
  end

  defp mouse(ctx, st, m, items) do
    size = Map.get(st, :size, {24, 80})
    n = length(items)
    view = %{first: 2, height: list_height(size), top: list_top(st, size), n: n}

    case Lepton.ListMouse.action(m, view, Map.get(st, :last)) do
      {:select, i, last} -> Map.put(%{st | sel: i}, :last, last)
      {:open, i} -> start(ctx, Map.put(%{st | sel: i}, :last, nil), Enum.at(items, i))
      {:move, d} -> %{st | sel: (st.sel + d) |> min(n - 1) |> max(0)}
      :none -> st
    end
  end

  defp start(ctx, st, station) do
    if st.player, do: Player.stop(st.player)

    case Lepton.Player.CLI.open(ctx, station.url, station.name, nil, icy: true, video: false) do
      {:ok, pid} -> %{st | player: pid, playing: station, status: Player.status(pid), message: nil}
      {:error, why} -> %{st | player: nil, playing: nil, status: nil, message: why}
    end
  end

  defp toggle(ctx, st) do
    cond do
      st.player && Process.alive?(st.player) -> Player.toggle(st.player); st
      st.playing -> start(ctx, st, st.playing)
      true -> st
    end
  end

  @doc false
  def screen(st, {rows, cols}) do
    items = list(st)
    height = max(rows - 7, 1)
    top = cond do
      st.sel < st.top -> st.sel
      st.sel >= st.top + height -> st.sel - height + 1
      true -> st.top
    end

    tabs = for {v, label} <- [mine: "Your stations", found: "Found"], do: if(st.view == v, do: "\e[7m #{label} \e[0m", else: " #{label} ")
    head = "\e[1m Radio\e[0m  " <> Enum.join(tabs, " ")

    body =
      for {s, i} <- items |> Enum.with_index() |> Enum.slice(top, height) do
        extra = Enum.join(Enum.reject([s.country, s.codec, if(s.bitrate > 0, do: "#{s.bitrate}k")], &(&1 in [nil, ""])), " ")
        playing = st.playing && st.playing.url == s.url
        mark = if playing, do: "♪ ", else: "  "
        label = String.slice(mark <> s.name, 0, max(cols - String.length(extra) - 4, 10))
        text = String.pad_trailing(label, max(cols - String.length(extra) - 3, 0)) <> extra
        if i == st.sel, do: "\e[7m #{text} \e[0m", else: " #{text}"
      end

    empty = if items == [], do: [if(st.view == :mine, do: "  No stations yet: / searches for some", else: "  / searches Radio Browser")], else: []

    now =
      case st.status do
        nil -> "\e[2m Nothing playing\e[0m"
        s -> " " <> Lepton.Player.CLI.line(s, 0, 1, cols - 1)
      end

    prompt = if st.search, do: "\e[1m Search: \e[0m#{st.search}\e[7m \e[0m", else: "\e[2m" <> String.slice(st.message || "Enter: play   Space: stop/start   /: search   a: add   d: remove   Tab: yours/found   9/0: volume   q: quit", 0, cols) <> "\e[0m"
    lines = [head, "" | body ++ empty]
    lines ++ List.duplicate("", max(height + 2 - length(lines), 0)) ++ ["", now, prompt]
  end
end
