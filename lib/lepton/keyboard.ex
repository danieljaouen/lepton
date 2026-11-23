defmodule Lepton.Keyboard do
  @moduledoc """
  The desktop's input sources: the keyboard layouts (and Korean) you
  type with in Photon, and which one is in use.

  A source is `"us"` (English), `"ko"` (Korean: the US keys, composed
  into Hangul by `Lepton.Hangul`), or a layout of `Lepton.Wayland.Layouts`
  (Thai, Hindi, Arabic, ...). Super+Space (and the classic taskbar's
  indicator) moves to the next one; in Korean, the Hangul key, Shift+Space
  or a tap of Right Alt switch between Hangul and English.

  The setting is the system's, kept in the state directory (`keyboard`)
  across reboots. Photon watches it (`watch/1`, `{:keyboard, state}`) and
  sends programs a keymap with US English as the first XKB group and each
  other layout as the next (at most four groups, as XKB allows).
  """
  use Agent

  alias Lepton.Wayland.Layouts

  @max_layouts 3
  @public [:sources, :current, :hangul, :accents, :caps]

  defstruct sources: ["us"], current: "us", hangul: true, accents: true, caps: :lock, watchers: []

  def start_link(_), do: Agent.start_link(fn -> load() |> console() end, name: __MODULE__)

  @doc """
  Read the settings again (at boot, once the data partition, where they
  are kept, is mounted), and tell the watchers.
  """
  def reload do
    if Process.whereis(__MODULE__), do: change(fn old -> %{load() | watchers: old.watchers} |> console() end)
    :ok
  end

  # The console starts with the kernel's keymap, where Caps Lock is a lock.
  defp console(st) do
    if st.caps == :ctrl, do: Lepton.Keyboard.Console.set_caps(:ctrl)
    st
  end

  @doc "Every source there is: `[{id, name}]`."
  def known do
    [{"us", "English (US)"}, {"ko", "Korean (Hangul, 2-set)"}] ++ Enum.map(Layouts.ids(), &{&1, elem(Layouts.get(&1), 0)})
  end

  def name(id), do: with({_, n} <- List.keyfind(known(), id, 0), do: n)

  @doc "The taskbar's label for a source (`EN`, `KO`, `TH`, ...)."
  def label("us"), do: "EN"
  def label(id), do: String.upcase(id)

  @doc """
  The state: `%{sources: [id], current: id, hangul: bool, accents: bool,
  caps: :lock | :ctrl}` (`hangul`: Korean types Hangul, not English;
  `accents`: the Alt keys type accents, `Lepton.Accents`; `caps`: what
  Caps Lock is, on the desktop and the text console).
  """
  def state do
    st = if Process.whereis(__MODULE__), do: Agent.get(__MODULE__, & &1), else: load()
    Map.take(st, @public)
  end

  @doc """
  The XKB groups for `sources`: US English, then each layout (Korean
  types through the US keys).
  """
  def groups(sources), do: ["us" | sources |> Enum.map(&layout/1) |> Enum.reject(&(&1 == "us")) |> Enum.uniq()]

  @doc "The layout (XKB group) a source types with."
  def layout(id) when id in ["us", "ko"], do: "us"
  def layout(id), do: id

  @doc "The group number of the current source (0: US)."
  def group(%{sources: s, current: c}), do: Enum.find_index(groups(s), &(&1 == layout(c))) || 0

  @doc "The layout of group `n` now (for Lepton's own windows, which get no keymap)."
  def group_layout(0), do: "us"
  def group_layout(n), do: Enum.at(groups(state().sources), n, "us")

  @doc "Use these sources (the first is used now unless the current one is among them)."
  def set_sources(ids) do
    ids = Enum.uniq(ids)
    unknown = Enum.reject(ids, &name/1)

    cond do
      ids == [] -> {:error, "no input sources"}
      unknown != [] -> {:error, "unknown input source: #{Enum.join(unknown, ", ")} (see `keyboard list`)"}
      length(groups(ids)) > @max_layouts + 1 -> {:error, "at most #{@max_layouts} layouts besides English (Korean doesn't count)"}
      true -> change(fn st -> %{st | sources: ids, current: if(st.current in ids, do: st.current, else: hd(ids)), hangul: true} end)
    end
  end

  @doc "Switch to source `id` (one of the sources)."
  def use(id) do
    if id in state().sources,
      do: change(&%{&1 | current: id, hangul: true}),
      else: {:error, "#{id} is not one of the input sources (`keyboard add #{id}`)"}
  end

  @doc "Switch to the next source (after the last, the first)."
  def next do
    change(fn st ->
      i = Enum.find_index(st.sources, &(&1 == st.current)) || 0
      %{st | current: Enum.at(st.sources, rem(i + 1, length(st.sources))), hangul: true}
    end)
  end

  @doc "Do the Alt keys type accents (`Lepton.Accents`)? On unless turned off."
  def accents?, do: state().accents

  @doc "Turn the accent keys on or off."
  def set_accents(on?) when is_boolean(on?), do: change(&%{&1 | accents: on?})

  @doc "What Caps Lock is: `:lock` (Caps Lock), or `:ctrl` (another Ctrl)."
  def caps, do: state().caps

  @doc """
  Make Caps Lock `:ctrl` or `:lock`, on the desktop (Photon) and the text
  console (the kernel's keymap, `Lepton.Keyboard.Console`).
  """
  def set_caps(caps) when caps in [:ctrl, :lock] do
    result = change(&%{&1 | caps: caps})
    Lepton.Keyboard.Console.set_caps(caps)
    result
  end

  @doc "In Korean: switch between Hangul and English."
  def toggle_hangul, do: change(&%{&1 | hangul: not &1.hangul})

  @doc "Send `pid` `{:keyboard, state}` whenever the state changes."
  def watch(pid) do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, &%{&1 | watchers: Enum.uniq([pid | &1.watchers])})
    :ok
  end

  defp change(fun) do
    if Process.whereis(__MODULE__) do
      {st, watchers} =
        Agent.get_and_update(__MODULE__, fn old ->
          new = fun.(old)
          ws = Enum.filter(new.watchers, &Process.alive?/1)
          {{new, ws}, %{new | watchers: ws}}
        end)

      save(st)
      public = Map.take(st, @public)
      for w <- watchers, do: send(w, {:keyboard, public})
      {:ok, public}
    else
      st = fun.(load())
      save(st)
      {:ok, Map.take(st, @public)}
    end
  end

  # -- the file: "sources us ko th", "current ko" (and "accents off", "caps ctrl") -----------------------

  defp path, do: Lepton.Persist.state_path("keyboard")

  defp load do
    case File.read(path()) do
      {:ok, text} ->
        lines = String.split(text, "\n", trim: true)
        sources = for("sources " <> s <- lines, id <- String.split(s), name(id), do: id) |> Enum.uniq()
        sources = if sources == [], do: ["us"], else: sources
        current = Enum.find_value(lines, fn "current " <> c -> String.trim(c); _ -> nil end)
        %__MODULE__{sources: sources, current: if(current in sources, do: current, else: hd(sources)), accents: "accents off" not in lines, caps: if("caps ctrl" in lines, do: :ctrl, else: :lock)}

      _ ->
        %__MODULE__{}
    end
  end

  defp save(st) do
    File.mkdir_p(Path.dirname(path()))
    accents = if st.accents, do: "", else: "accents off\n"
    caps = if st.caps == :ctrl, do: "caps ctrl\n", else: ""
    File.write(path(), "sources #{Enum.join(st.sources, " ")}\ncurrent #{st.current}\n" <> accents <> caps)
  end
end
