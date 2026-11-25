defmodule Lepton.Torrent.CLI do
  @moduledoc """
  `torrent` in a terminal (the desktop's Torrents): your torrents, their
  progress, speeds and peers, updated each second. `a` adds one (a
  magnet link, a `.torrent` file or its address), Space stops or starts
  the one selected, `d` removes it (`D`: its files too, after asking),
  `o` shows its folder's path, `q` quits (the downloads go on).
  """

  alias Lepton.{Torrent, TTY}

  def run(ctx) do
    tty = ctx.tty
    TTY.set_mode(tty, :raw)
    TTY.write(tty, "\e[?1049h\e[?25l")

    try do
      loop(ctx, tty, %{sel: 0, input: nil, confirm: nil, message: nil})
    after
      TTY.write(tty, "\e[0m\e[?25h\e[?1049l")
      TTY.set_mode(tty, :cooked)
    end
  end

  defp loop(ctx, tty, st) do
    list = Torrent.list(ctx)
    st = %{st | sel: st.sel |> min(length(list) - 1) |> max(0)}
    TTY.write(tty, ["\e[H\e[2J", Enum.join(screen(st, list, TTY.size(tty)), "\r\n")])

    case TTY.read_key(tty, 1000) do
      :timeout -> loop(ctx, tty, st)
      key ->
        case key(ctx, st, list, key) do
          :quit -> 0
          st -> loop(ctx, tty, st)
        end
    end
  end

  @doc false
  def key(ctx, %{input: text} = st, _list, key) when is_binary(text) do
    case key do
      "RET" ->
        st = %{st | input: nil}

        case Torrent.add(ctx, String.trim(text)) do
          {:ok, id} -> %{st | message: "Added #{Torrent.short(id)}"}
          {:error, why} -> %{st | message: why}
        end

      k when k in ["ESC", "C-g"] -> %{st | input: nil}
      "DEL" -> %{st | input: String.slice(text, 0..-2//1)}
      "SPC" -> %{st | input: text <> " "}
      {:paste, p} -> %{st | input: text <> String.trim(p)}
      k when is_binary(k) -> if String.length(k) == 1, do: %{st | input: text <> k}, else: st
      _ -> st
    end
  end

  def key(ctx, %{confirm: {:delete, t}} = st, _list, key) do
    if key in ["y", "Y"] do
      Torrent.remove(ctx, t.id, delete: true)
      %{st | confirm: nil, message: "Removed #{t.name} and its files"}
    else
      %{st | confirm: nil, message: nil}
    end
  end

  def key(ctx, st, list, key) do
    t = Enum.at(list, st.sel)

    case key do
      k when k in ["q", "C-c", "ESC"] -> :quit
      k when k in ["<down>", "j", "C-n"] -> %{st | sel: st.sel + 1}
      k when k in ["<up>", "k", "C-p"] -> %{st | sel: st.sel - 1}
      "a" -> %{st | input: "", message: nil}
      k when k in ["SPC", " "] and t != nil ->
        if t.state == :stopped do
          case Torrent.start(ctx, t.id) do
            :ok -> %{st | message: "Started #{t.name}"}
            {:error, why} -> %{st | message: why}
          end
        else
          Torrent.stop(ctx, t.id)
          %{st | message: "Stopped #{t.name}"}
        end

      "d" when t != nil -> Torrent.remove(ctx, t.id); %{st | message: "Removed #{t.name} (its files stay)"}
      "D" when t != nil -> %{st | confirm: {:delete, t}}
      "o" when t != nil -> %{st | message: "In #{t.dir}"}
      _ -> st
    end
  end

  @doc false
  def screen(st, list, {rows, cols}) do
    head = "\e[1m Torrents\e[0m  #{length(list)} " <> if(length(list) == 1, do: "torrent", else: "torrents")
    body = if list == [], do: ["", "  None yet: a adds a magnet link or a .torrent file (its path or address)."], else: Enum.flat_map(Enum.with_index(list), &entry(&1, st.sel, cols))

    foot =
      cond do
        st.input -> "\e[1m Add (magnet, file or address): \e[0m#{st.input}\e[7m \e[0m"
        match?({:delete, _}, st.confirm) -> "\e[1m Remove #{elem(st.confirm, 1).name} and delete its files? (y/n)\e[0m"
        true -> "\e[2m" <> String.slice(st.message || "a: add   Space: stop/start   d: remove   D: remove and delete files   o: folder   q: quit (downloads go on)", 0, cols) <> "\e[0m"
      end

    lines = [head, "" | body]
    Enum.take(lines, rows - 2) ++ List.duplicate("", max(rows - 2 - length(lines), 0)) ++ ["", foot]
  end

  defp entry({t, i}, sel, cols) do
    {name, detail} = describe(t)
    width = max(cols - 4, 10)
    bar_w = min(30, max(width - 50, 10))
    pct = t.progress && min(t.progress, 1.0)
    bar = if pct, do: "[" <> String.duplicate("#", round(bar_w * pct)) <> String.duplicate(".", bar_w - round(bar_w * pct)) <> "] " <> String.pad_leading("#{Float.round(pct * 100, 1)}%", 6), else: ""
    title = String.slice("#{i + 1}. #{name}", 0, width)
    first = if i == sel, do: "\e[7m #{String.pad_trailing(title, width)} \e[0m", else: " \e[1m#{title}\e[0m"
    [first, "    " <> String.slice(Enum.join(Enum.reject([bar, detail], &(&1 == "")), "  "), 0, width)]
  end

  @doc "A torrent's name and a line about it: state, size, speeds, peers."
  def describe(t) do
    state =
      case t.state do
        :metadata -> "getting the file list"
        :checking -> "checking"
        :downloading -> "downloading"
        :seeding -> "seeding"
        :stopped -> "stopped"
        other -> to_string(other)
      end

    parts =
      case t.state do
        :stopped -> [state, t.dir]
        _ ->
          [
            state,
            t.size && "#{Torrent.human(t.done)} of #{Torrent.human(t.size)}",
            "↓ #{Torrent.human(t.down_rate)}/s",
            "↑ #{Torrent.human(t.up_rate)}/s",
            "#{t.peers} peers",
            t.state == :downloading && t.eta && "#{Torrent.eta(t.eta)} left"
          ]
      end

    {t.name, parts |> Enum.reject(&(&1 in [nil, false])) |> Enum.join(", ")}
  end
end
