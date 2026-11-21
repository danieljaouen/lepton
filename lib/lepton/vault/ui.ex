defmodule Lepton.Vault.UI do
  @moduledoc """
  The Passwords window's contents (the vault, `Lepton.Vault`, on the
  desktop), apart from Wayland: a state, the events that change it, and a
  drawing of it, in the classic desktop's grey 3D style.

    * no vault yet: choose a master password and make one;
    * locked: the master password unlocks it;
    * unlocked: a search field and the items on the left, the selected
      item on the right (secrets hidden until **Show**, **Copy** for each
      field, the one-time password's code counting down); a toolbar to add,
      edit and delete items, generate passwords and lock.

  Keys: Tab and Shift+Tab move between fields, Return unlocks, saves or
  copies the password, Escape cancels; Up and Down choose an item;
  Ctrl+F searches, Ctrl+N adds, Ctrl+E edits, Ctrl+C copies the password,
  Ctrl+L locks; Ctrl+V pastes into a field.

  `handle/2` takes `{:key, name, mods}` (`Lepton.Wayland.Keymap` names),
  `{:click, x, y}`, `{:wheel, n}`, `:tick` and `{:resize, w, h}`;
  `render/1` returns the pixels as a `Lepton.Photon.Canvas`. Clicks go to
  the regions the last drawing recorded.
  """

  alias Lepton.Photon.{Canvas, Render}
  alias Lepton.Vault
  alias Lepton.Wayland.Keymap

  import Bitwise

  @face "#c0c0c0"
  @white "#ffffff"
  @shadow "#808080"
  @dark "#000000"
  @navy "#000080"
  @red "#c00000"
  @green "#008000"

  @toolbar 32
  @status 22
  @list_w 220
  @row_h 36
  @line 24

  def new(opts) do
    st = %{
      user: Keyword.fetch!(opts, :user),
      path: Keyword.fetch!(opts, :path),
      w: opts[:w] || 640,
      h: opts[:h] || 420,
      screen: :locked,
      items: [],
      selected: nil,
      scroll: 0,
      focus: :master,
      text: %{master: "", again: "", search: ""},
      mode: :view,
      draft: %{},
      reveal: MapSet.new(),
      message: nil,
      error: nil,
      gen: %{length: 20, symbols: true, value: Vault.generate()},
      mtime: nil,
      regions: []
    }

    refresh_screen(st)
  end

  defp refresh_screen(st) do
    cond do
      not Vault.exists?(st.path) -> %{st | screen: :setup, focus: :master}
      Vault.unlocked?(st.user, st.path) -> load(%{st | screen: :main, focus: :search})
      true -> %{st | screen: :locked, focus: :master}
    end
  end

  # The items, again (after a change, or the file changed under us).
  defp load(st) do
    case Vault.items(st.user, st.path) do
      {:ok, items} ->
        sel = if Enum.any?(items, &(&1["id"] == st.selected)), do: st.selected, else: (List.first(items) || %{})["id"]
        %{st | items: items, selected: sel, mtime: mtime(st.path)}

      {:error, _} ->
        lock_screen(st, "The vault is locked.")
    end
  end

  defp mtime(path), do: with({:ok, %{mtime: m}} <- File.stat(path), do: m, else: (_ -> nil))

  defp lock_screen(st, msg) do
    %{st | screen: :locked, items: [], draft: %{}, mode: :view, reveal: MapSet.new(), focus: :master, text: %{st.text | master: "", again: ""}, message: msg, error: nil}
  end

  @doc "The items shown: those the search matches."
  def shown(st), do: Vault.search(st.items, st.text.search)

  def selected(st), do: Enum.find(st.items, &(&1["id"] == st.selected))

  # -- events ----------------------------------------------------------------------------------

  def handle(st, {:resize, w, h}), do: %{st | w: max(w, 480), h: max(h, 320)}

  # Locked meanwhile (idle, `vault lock`), or changed by `vault` in a terminal.
  def handle(%{screen: :main} = st, :tick) do
    cond do
      not Vault.unlocked?(st.user, st.path) -> lock_screen(st, "Locked after being idle (or by vault lock).")
      mtime(st.path) != st.mtime and st.mode == :view -> load(st)
      true -> st
    end
  end

  def handle(st, :tick), do: if(st.screen == :locked and Vault.unlocked?(st.user, st.path), do: refresh_screen(st), else: st)

  def handle(st, {:wheel, n}) do
    max_scroll = max(length(shown(st)) - visible_rows(st), 0)
    %{st | scroll: min(max(st.scroll + n * 3, 0), max_scroll)}
  end

  def handle(st, {:click, x, y}) do
    case Enum.find(st.regions, fn {rx, ry, rw, rh, _} -> x >= rx and x < rx + rw and y >= ry and y < ry + rh end) do
      {_, _, _, _, action} -> act(%{st | message: nil}, action)
      nil -> st
    end
  end

  def handle(st, {:key, key, mods}) do
    shift? = band(mods, Keymap.shift()) != 0
    st = if key in ["TAB", "RET", "ESC"], do: st, else: %{st | error: nil}

    case {st.screen, st.mode, key} do
      {_, _, "TAB"} -> move_focus(st, if(shift?, do: -1, else: 1))
      {:setup, _, "RET"} -> act(st, :create)
      {:locked, _, "RET"} -> act(st, :unlock)
      {:main, m, "ESC"} when m != :view -> %{st | mode: :view, focus: :search, error: nil}
      {:main, :view, "ESC"} -> put_text(%{st | scroll: 0}, :search, "")
      {:main, m, "RET"} when m in [:edit, :new] and st.focus != {:draft, "notes"} -> act(st, :save)
      {:main, m, "C-s"} when m in [:edit, :new] -> act(st, :save)
      {:main, :confirm, "RET"} -> act(st, :confirm_delete)
      {:main, :view, "RET"} -> act(st, {:copy, "password"})
      {:main, :view, "<down>"} -> move_selection(st, 1)
      {:main, :view, "<up>"} -> move_selection(st, -1)
      {:main, :view, "<next>"} -> move_selection(st, visible_rows(st))
      {:main, :view, "<prior>"} -> move_selection(st, -visible_rows(st))
      {:main, :view, "<deletechar>"} when st.selected != nil -> act(st, :delete)
      {:main, _, "C-f"} -> %{st | mode: if(st.mode == :confirm, do: :view, else: st.mode), focus: :search}
      {:main, _, "C-n"} -> act(st, :new)
      {:main, :view, "C-e"} -> act(st, :edit)
      {:main, :view, "C-c"} -> act(st, {:copy, "password"})
      {:main, _, "C-l"} -> act(st, :lock)
      {_, _, key} -> type(st, key)
    end
  end

  def handle(st, _), do: st

  defp move_selection(st, d) do
    items = shown(st)

    case Enum.find_index(items, &(&1["id"] == st.selected)) do
      nil -> %{st | selected: (List.first(items) || %{})["id"]} |> keep_visible()
      i -> %{st | selected: Enum.at(items, min(max(i + d, 0), length(items) - 1))["id"], reveal: MapSet.new()} |> keep_visible()
    end
  end

  defp keep_visible(st) do
    i = Enum.find_index(shown(st), &(&1["id"] == st.selected)) || 0
    rows = visible_rows(st)

    cond do
      i < st.scroll -> %{st | scroll: i}
      i >= st.scroll + rows -> %{st | scroll: i - rows + 1}
      true -> st
    end
  end

  # The fields Tab goes through.
  defp focusable(%{screen: :setup}), do: [:master, :again]
  defp focusable(%{screen: :locked}), do: [:master]
  defp focusable(%{mode: m} = st) when m in [:edit, :new], do: [:search | Enum.map(form_fields(st.draft), &{:draft, &1})]
  defp focusable(_), do: [:search]

  defp move_focus(st, d) do
    fs = focusable(st)
    i = Enum.find_index(fs, &(&1 == st.focus)) || 0
    %{st | focus: Enum.at(fs, rem(i + d + length(fs), length(fs)))}
  end

  # Typing into the focused field.
  defp type(st, key) do
    old = get_text(st, st.focus)

    new =
      case key do
        "DEL" -> String.slice(old, 0..-2//1)
        "C-u" -> ""
        "C-v" -> old <> Lepton.Clipboard.get()
        "SPC" -> old <> " "
        "RET" -> old <> "\n"
        <<c::utf8>> when c >= 32 -> old <> key
        _ -> nil
      end

    if new == nil or old == nil, do: st, else: put_text(st, st.focus, new)
  end

  defp get_text(st, {:draft, f}), do: st.draft[f] || ""
  defp get_text(st, k) when is_map_key(st.text, k), do: st.text[k]
  defp get_text(_, _), do: nil

  defp put_text(st, {:draft, f}, v), do: %{st | draft: Map.put(st.draft, f, v)}

  defp put_text(st, :search, v) do
    st = %{st | text: %{st.text | search: v}, scroll: 0}
    if st.selected in Enum.map(shown(st), & &1["id"]), do: st, else: %{st | selected: (List.first(shown(st)) || %{})["id"]}
  end

  defp put_text(st, k, v), do: %{st | text: Map.put(st.text, k, v)}

  # -- actions ---------------------------------------------------------------------------------

  defp act(st, {:focus, f}), do: %{st | focus: f}

  defp act(st, :create) do
    %{master: pw, again: again} = st.text

    cond do
      pw != again -> %{st | error: "The passwords don't match.", text: %{st.text | again: ""}, focus: :again}
      true ->
        case Vault.create(st.user, st.path, pw) do
          :ok -> load(%{st | screen: :main, focus: :search, text: %{st.text | master: "", again: ""}, message: "Your vault is ready. New adds a login."})
          {:error, r} -> %{st | error: Vault.describe(r) |> capitalize()}
        end
    end
  end

  defp act(st, :unlock) do
    case Vault.unlock(st.user, st.path, st.text.master) do
      :ok -> load(%{st | screen: :main, focus: :search, text: %{st.text | master: ""}, message: nil, error: nil})
      {:error, r} -> %{st | error: Vault.describe(r) |> capitalize(), text: %{st.text | master: ""}}
    end
  end

  defp act(st, :lock) do
    Vault.lock(st.user, st.path)
    lock_screen(st, nil)
  end

  # (Not while a form is open: it is about the item it was opened for.)
  defp act(%{mode: m} = st, {:select, _}) when m in [:edit, :new], do: st
  defp act(st, {:select, id}), do: %{st | selected: id, mode: :view, reveal: MapSet.new()}

  defp act(st, :new), do: %{st | mode: :new, draft: %{"kind" => "login", "title" => "", "password" => Vault.generate()}, focus: {:draft, "title"}, reveal: MapSet.new()}

  defp act(st, :edit) do
    case selected(st) do
      nil -> st
      item ->
        draft = item |> Map.take(["kind" | form_fields(item)]) |> Map.put("tags", Enum.join(item["tags"] || [], ", "))
        %{st | mode: :edit, draft: draft, focus: {:draft, "title"}, reveal: MapSet.new()}
    end
  end

  defp act(st, {:kind, kind}), do: %{st | draft: Map.put(st.draft, "kind", kind)}

  defp act(st, :save) do
    d = st.draft
    title = String.trim(d["title"] || "")
    fields = Map.take(d, form_fields(d)) |> Map.put("title", title) |> Map.put("kind", d["kind"])

    cond do
      title == "" ->
        %{st | error: "Give it a title.", focus: {:draft, "title"}}

      st.mode == :new ->
        item = Vault.new_item(fields)
        {:ok, _} = Vault.update(st.user, st.path, &{:ok, [item | &1], nil})
        load(%{st | mode: :view, selected: item["id"], focus: :search, message: "Added #{title}."}) |> keep_visible()

      true ->
        id = st.selected

        case Vault.update(st.user, st.path, fn items ->
               case Enum.find(items, &(&1["id"] == id)) do
                 nil -> {:error, :not_found}
                 item -> {:ok, Vault.replace(items, Vault.set_fields(item, fields)), nil}
               end
             end) do
          {:ok, _} -> load(%{st | mode: :view, focus: :search, message: "Saved #{title}."})
          {:error, r} -> %{st | error: Vault.describe(r) |> capitalize()}
        end
    end
  end

  defp act(st, :cancel), do: %{st | mode: :view, focus: :search, error: nil}

  defp act(st, :delete), do: if(selected(st), do: %{st | mode: :confirm}, else: st)

  defp act(st, :confirm_delete) do
    item = selected(st)
    {:ok, _} = Vault.update(st.user, st.path, &{:ok, Vault.delete(&1, item["id"]), nil})
    load(%{st | mode: :view, selected: nil, message: "Deleted #{item["title"]}."})
  end

  defp act(st, {:copy, field}) do
    with item when item != nil <- selected(st),
         {:ok, v} <- field_value(item, field) do
      Vault.copy(v)
      # Copying counts as using the vault (it stays unlocked).
      _ = Vault.items(st.user, st.path)
      %{st | message: "Copied the #{field}. The clipboard is cleared in 45 seconds."}
    else
      _ -> st
    end
  end

  defp act(st, {:reveal, f}), do: %{st | reveal: if(f in st.reveal, do: MapSet.delete(st.reveal, f), else: MapSet.put(st.reveal, f))}

  defp act(st, :generate_into), do: %{st | draft: Map.put(st.draft, "password", Vault.generate(length: st.gen.length, symbols: st.gen.symbols)), reveal: MapSet.put(st.reveal, "password")}

  defp act(st, :generator), do: %{st | mode: :generator, gen: %{st.gen | value: new_gen(st.gen)}}
  defp act(st, {:gen_length, d}), do: put_gen(st, :length, min(max(st.gen.length + d, 8), 64))
  defp act(st, :gen_symbols), do: put_gen(st, :symbols, not st.gen.symbols)
  defp act(st, :gen_new), do: %{st | gen: %{st.gen | value: new_gen(st.gen)}}

  defp act(st, :gen_copy) do
    Vault.copy(st.gen.value)
    %{st | message: "Copied the password. The clipboard is cleared in 45 seconds."}
  end

  defp act(st, _), do: st

  defp put_gen(st, k, v) do
    gen = Map.put(st.gen, k, v)
    %{st | gen: %{gen | value: new_gen(gen)}}
  end

  defp new_gen(gen), do: Vault.generate(length: gen.length, symbols: gen.symbols)

  defp field_value(item, "otp") do
    case Vault.totp(item["otp"] || "") do
      {:ok, code, _} -> {:ok, code}
      _ -> :error
    end
  end

  defp field_value(item, f), do: if(is_binary(item[f]), do: {:ok, item[f]}, else: :error)

  # The form's fields: title, the kind's fields and any others the item has, tags.
  defp form_fields(item) do
    extra = Vault.shown_fields(Map.delete(item, "tags")) -- Vault.known_fields()
    ["title" | Vault.fields(item["kind"])] ++ (extra -- ["title"]) ++ ["tags"]
  end

  defp capitalize(<<c::utf8, rest::binary>>), do: String.upcase(<<c::utf8>>) <> rest

  # -- drawing ---------------------------------------------------------------------------------

  defp px(hex), do: Render.rgb(hex)

  @doc "Draw the window: `{canvas, st}` (the state keeps where things were, for clicks)."
  def render(st) do
    d = %{c: Canvas.new(st.w, st.h, px(@face)), r: []}

    d =
      case st.screen do
        :setup -> setup_screen(d, st)
        :locked -> locked_screen(d, st)
        :main -> main_screen(d, st)
      end

    {d.c, %{st | regions: d.r}}
  end

  defp region(d, x, y, w, h, action), do: %{d | r: [{x, y, w, h, action} | d.r]}

  defp text(d, x, y, s, opts \\ []) do
    fg = px(opts[:fg] || @dark)
    bg = px(opts[:bg] || @face)
    %{d | c: Canvas.text(d.c, x, y, s, fg, bg, Keyword.take(opts, [:bold, :max_w]))}
  end

  defp button(d, x, y, label, action, opts \\ []) do
    w = opts[:w] || Canvas.text_width(label) + 20
    style = if opts[:pressed], do: :sunken, else: :raised
    d = %{d | c: Canvas.bevel(d.c, x, y, w, 24, style)}
    d = text(d, x + div(w - Canvas.text_width(label), 2), y + 4, label, fg: if(opts[:disabled], do: @shadow, else: @dark))
    if opts[:disabled], do: d, else: region(d, x, y, w, 24, action)
  end

  defp button_width(label), do: Canvas.text_width(label) + 20

  # A text field: sunken and white, the end of the text shown, a caret when focused.
  defp field(d, st, x, y, w, key, opts \\ []) do
    value = get_text(st, key) || ""
    masked? = opts[:masked] == true
    h = (opts[:lines] || 1) * 16 + 8
    d = %{d | c: Canvas.bevel(d.c, x, y, w, h, :sunken, @white)}
    cols = div(w - 10, 8)

    lines =
      if opts[:lines] do
        value |> String.split("\n") |> Enum.flat_map(&wrap(&1, cols)) |> Enum.take(-opts[:lines])
      else
        shown = if masked?, do: String.duplicate("*", String.length(value)), else: String.replace(value, "\n", " ")
        [String.slice(shown, max(String.length(shown) - cols + 1, 0)..-1//1)]
      end

    d = lines |> Enum.with_index() |> Enum.reduce(d, fn {l, i}, d -> text(d, x + 4, y + 4 + i * 16, l, bg: @white) end)

    d =
      if st.focus == key do
        last = List.last(lines) || ""
        %{d | c: Canvas.fill(d.c, x + 4 + min(String.length(last), cols - 1) * 8, y + 4 + (length(lines) - 1) * 16, 1, 16, px(@dark))}
      else
        d
      end

    region(d, x, y, w, h, {:focus, key})
  end

  defp wrap("", _), do: [""]
  defp wrap(s, cols), do: s |> String.graphemes() |> Enum.chunk_every(max(cols - 1, 1)) |> Enum.map(&Enum.join/1)

  # A big padlock, for the locked and setup screens.
  @lock_art [
    "     kkkkkk     ",
    "    kk    kk    ",
    "   kk      kk   ",
    "   k        k   ",
    "   k        k   ",
    "   k        k   ",
    " kkkkkkkkkkkkkk ",
    " kyyyyyyyyyyyyk ",
    " kyyyyykkyyyyyk ",
    " kyyyykkkkyyyyk ",
    " kyyyyykkyyyyyk ",
    " kyyyyykkyyyyyk ",
    " kyyyyykkyyyyyk ",
    " kyyyyyyyyyyyyk ",
    " kkkkkkkkkkkkkk "
  ]

  defp padlock(d, x, y) do
    art = for row <- @lock_art, line = Enum.map_join(String.graphemes(row), &String.duplicate(&1, 3)), _ <- 1..3, do: line
    %{d | c: Canvas.art(d.c, x, y, art, %{"k" => @dark, "y" => "#d4a017"})}
  end

  defp centered_box(d, st, w, h) do
    x = div(st.w - w, 2)
    y = max(div(st.h - h, 2), 8)
    {%{d | c: Canvas.bevel(d.c, x, y, w, h, :raised)}, x, y}
  end

  defp setup_screen(d, st) do
    {d, x, y} = centered_box(d, st, 400, 300)
    d = padlock(d, x + 176, y + 16)
    d = text(d, x + 20, y + 70, "Make your vault", bold: true)
    d = text(d, x + 20, y + 92, "Choose a master password (8 or more")
    d = text(d, x + 20, y + 108, "characters). Nothing can recover it.")
    d = text(d, x + 20, y + 136, "Master password:")
    d = field(d, st, x + 160, y + 132, 220, :master, masked: true)
    d = text(d, x + 20, y + 168, "Again:")
    d = field(d, st, x + 160, y + 164, 220, :again, masked: true)
    d = if st.error, do: text(d, x + 20, y + 204, st.error, fg: @red, max_w: 360), else: d
    button(d, x + 400 - 20 - button_width("Make vault"), y + 300 - 40, "Make vault", :create)
  end

  defp locked_screen(d, st) do
    {d, x, y} = centered_box(d, st, 400, 230)
    d = padlock(d, x + 176, y + 16)
    d = text(d, x + 20, y + 70, "The vault is locked", bold: true)
    d = text(d, x + 20, y + 102, "Master password:")
    d = field(d, st, x + 160, y + 98, 220, :master, masked: true)
    d = if st.error || st.message, do: text(d, x + 20, y + 138, st.error || st.message, fg: if(st.error, do: @red, else: @dark), max_w: 360), else: d
    button(d, x + 400 - 20 - button_width("Unlock"), y + 230 - 40, "Unlock", :unlock)
  end

  defp main_screen(d, st) do
    d = toolbar(d, st)
    d = list_pane(d, st)

    d =
      case st.mode do
        m when m in [:edit, :new] -> form_pane(d, st)
        :generator -> generator_pane(d, st)
        :confirm -> confirm_pane(d, st)
        :view -> detail_pane(d, st)
      end

    status_bar(d, st)
  end

  defp toolbar(d, st) do
    sel? = selected(st) != nil

    {d, _} =
      [{"New", :new, false}, {"Edit", :edit, not sel?}, {"Delete", :delete, not sel?}, {"Generator", :generator, false}]
      |> Enum.reduce({d, 4}, fn {label, action, disabled}, {d, x} ->
        {button(d, x, 4, label, action, disabled: disabled or st.mode in [:edit, :new], pressed: st.mode == action), x + button_width(label) + 4}
      end)

    d = button(d, st.w - 4 - button_width("Lock"), 4, "Lock", :lock)
    %{d | c: Canvas.bevel(d.c, 0, @toolbar - 2, st.w, 2, :thin_sunken)}
  end

  defp visible_rows(st), do: max(div(st.h - @toolbar - 34 - @status - 8, @row_h), 1)

  defp list_pane(d, st) do
    y0 = @toolbar + 4
    d = field(d, st, 4, y0, @list_w, :search)
    d = if st.text.search == "" and st.focus != :search, do: text(d, 8, y0 + 4, "Search", fg: @shadow, bg: @white), else: d
    top = y0 + 30
    h = st.h - top - @status - 4
    d = %{d | c: Canvas.bevel(d.c, 4, top, @list_w, h, :sunken, @white)}
    items = shown(st) |> Enum.drop(st.scroll) |> Enum.take(visible_rows(st))

    d =
      items
      |> Enum.with_index()
      |> Enum.reduce(d, fn {item, i}, d ->
        y = top + 3 + i * @row_h
        sel? = item["id"] == st.selected
        bg = if sel?, do: @navy, else: @white
        d = if sel?, do: %{d | c: Canvas.fill(d.c, 6, y, @list_w - 4, @row_h - 1, px(@navy))}, else: d
        title = (if item["favorite"], do: "* ", else: "") <> item["title"]
        d = text(d, 10, y + 2, title, bold: true, fg: if(sel?, do: @white, else: @dark), bg: bg, max_w: @list_w - 14)
        d = text(d, 10, y + 18, subtitle(item), fg: if(sel?, do: "#c0c0ff", else: @shadow), bg: bg, max_w: @list_w - 14)
        region(d, 6, y, @list_w - 4, @row_h, {:select, item["id"]})
      end)

    cond do
      st.items == [] -> text(d, 12, top + 8, "No items yet.", fg: @shadow, bg: @white)
      items == [] -> text(d, 12, top + 8, "Nothing matches.", fg: @shadow, bg: @white)
      true -> d
    end
  end

  defp subtitle(%{"kind" => "card"} = i), do: if(n = i["number"], do: "Card ending " <> String.slice(n, -4..-1//1), else: "Card")
  defp subtitle(%{"kind" => "note"}), do: "Secure note"
  defp subtitle(i), do: i["username"] || i["url"] || ""

  defp pane(st), do: {@list_w + 12, @toolbar + 4, st.w - @list_w - 16, st.h - @toolbar - @status - 8}

  defp detail_pane(d, st) do
    {x, y, w, h} = pane(st)
    d = %{d | c: Canvas.bevel(d.c, x, y, w, h, :sunken, @white)}

    case selected(st) do
      nil ->
        text(d, x + 16, y + 16, if(st.items == [], do: "New adds your first login.", else: "Choose an item."), fg: @shadow, bg: @white)

      item ->
        d = text(d, x + 12, y + 10, item["title"], bold: true, bg: @white, max_w: w - 24)
        d = text(d, x + 12, y + 28, "#{String.capitalize(item["kind"])}, changed #{String.slice(item["updated"], 0, 10)}", fg: @shadow, bg: @white, max_w: w - 24)
        fields = Vault.shown_fields(item) ++ if((item["tags"] || []) != [], do: ["tags"], else: [])

        fields
        |> Enum.with_index()
        |> Enum.reduce(d, fn {f, i}, d -> detail_row(d, st, item, f, x + 12, y + 56 + i * @line, w - 24) end)
    end
  end

  defp detail_row(d, st, item, f, x, y, w) do
    d = text(d, x, y + 4, label(f), fg: @shadow, bg: @white)
    vx = x + 96
    buttons_w = if Vault.secret?(f) and f != "otp", do: 112, else: 56
    max_w = w - 96 - buttons_w

    {value, copy?} =
      case f do
        "otp" ->
          case Vault.totp(item["otp"]) do
            {:ok, code, left} -> {String.slice(code, 0, 3) <> " " <> String.slice(code, 3..-1//1) <> "   #{left}s", true}
            _ -> {"(not a TOTP secret)", false}
          end

        "tags" ->
          {Enum.join(item["tags"], ", "), false}

        f ->
          v = to_string(item[f])
          {if(Vault.secret?(f) and f not in st.reveal, do: String.duplicate("*", min(String.length(v), 16)), else: String.replace(v, "\n", " / ")), true}
      end

    d = text(d, vx, y + 4, value, bg: @white, max_w: max_w, fg: if(f == "otp", do: @navy, else: @dark), bold: f == "otp")

    d =
      if f == "password" and item["password"] do
        {s, _} = Vault.strength(item["password"])
        %{d | c: Canvas.fill(d.c, vx, y + 21, 48, 2, px(strength_color(s)))}
      else
        d
      end

    d = if copy?, do: button(d, x + w - 52, y, "Copy", {:copy, f}, w: 52), else: d
    if Vault.secret?(f) and f != "otp", do: button(d, x + w - 108, y, if(f in st.reveal, do: "Hide", else: "Show"), {:reveal, f}, w: 52), else: d
  end

  defp strength_color(:weak), do: @red
  defp strength_color(:fair), do: "#d4a017"
  defp strength_color(_), do: @green

  @labels %{"otp" => "one-time", "url" => "website", "cardholder" => "name", "number" => "number", "expiry" => "expires", "code" => "code"}
  defp label(f), do: Map.get(@labels, f, f)

  defp form_pane(d, st) do
    {x, y, w, h} = pane(st)
    d = %{d | c: Canvas.bevel(d.c, x, y, w, h, :raised)}
    d = text(d, x + 12, y + 8, if(st.mode == :new, do: "New item", else: "Edit item"), bold: true)

    # The kind (new items only): one button each.
    {d, fy} =
      if st.mode == :new do
        {d, _} =
          Enum.reduce(Vault.kinds(), {d, x + 108}, fn k, {d, bx} ->
            {button(d, bx, y + 30, String.capitalize(k), {:kind, k}, pressed: st.draft["kind"] == k, w: 64), bx + 68}
          end)

        {text(d, x + 12, y + 34, "Kind:"), y + 62}
      else
        {d, y + 34}
      end

    fw = w - 120

    {d, fy} =
      Enum.reduce(form_fields(st.draft), {d, fy}, fn f, {d, fy} ->
        d = text(d, x + 12, fy + 4, label(f) <> ":")

        cond do
          f == "notes" ->
            {field(d, st, x + 108, fy, fw, {:draft, f}, lines: 3), fy + 62}

          f == "password" ->
            d = field(d, st, x + 108, fy, fw - 120, {:draft, f}, masked: "password" not in st.reveal)
            d = button(d, x + 108 + fw - 116, fy, if("password" in st.reveal, do: "Hide", else: "Show"), {:reveal, "password"}, w: 52)
            {button(d, x + 108 + fw - 60, fy, "New", :generate_into, w: 60), fy + 28}

          true ->
            {field(d, st, x + 108, fy, fw, {:draft, f}), fy + 28}
        end
      end)

    d = if st.error, do: text(d, x + 12, fy + 6, st.error, fg: @red, max_w: w - 24), else: d
    by = y + h - 34
    d = button(d, x + w - 12 - 80, by, "Cancel", :cancel, w: 80)
    button(d, x + w - 12 - 168, by, "Save", :save, w: 80)
  end

  defp generator_pane(d, st) do
    {x, y, w, h} = pane(st)
    d = %{d | c: Canvas.bevel(d.c, x, y, w, h, :raised)}
    d = text(d, x + 12, y + 8, "Password generator", bold: true)
    d = %{d | c: Canvas.bevel(d.c, x + 12, y + 34, w - 24, 28, :sunken, @white)}
    d = text(d, x + 18, y + 40, st.gen.value, bg: @white, max_w: w - 36)
    {s, bits} = Vault.strength(st.gen.value)
    d = text(d, x + 12, y + 70, "#{String.capitalize(to_string(s))}: about #{bits} bits", fg: strength_color(s))
    d = text(d, x + 12, y + 100, "Length: #{st.gen.length}")
    d = button(d, x + 140, y + 96, "-", {:gen_length, -1}, w: 28)
    d = button(d, x + 172, y + 96, "+", {:gen_length, 1}, w: 28)
    d = button(d, x + 12, y + 128, if(st.gen.symbols, do: "[x] Symbols", else: "[ ] Symbols"), :gen_symbols)
    d = button(d, x + 12, y + 168, "New password", :gen_new)
    button(d, x + 12 + button_width("New password") + 6, y + 168, "Copy", :gen_copy, w: 64)
    |> button(x + w - 12 - 80, y + h - 34, "Close", :cancel, w: 80)
  end

  defp confirm_pane(d, st) do
    {x, y, w, h} = pane(st)
    d = %{d | c: Canvas.bevel(d.c, x, y, w, h, :raised)}
    item = selected(st) || %{"title" => ""}
    d = text(d, x + 16, y + 20, "Delete #{item["title"]}?", bold: true, max_w: w - 32)
    d = text(d, x + 16, y + 44, "It can't be brought back.")
    d = button(d, x + 16, y + 76, "Delete", :confirm_delete, w: 80)
    button(d, x + 104, y + 76, "Cancel", :cancel, w: 80)
  end

  defp status_bar(d, st) do
    y = st.h - @status
    d = %{d | c: Canvas.bevel(d.c, 2, y + 2, st.w - 4, @status - 4, :thin_sunken)}
    n = length(st.items)
    msg = st.error || st.message || "#{n} item#{if n == 1, do: "", else: "s"}"
    text(d, 8, y + 3, msg, fg: if(st.error, do: @red, else: @dark), max_w: st.w - 16)
  end
end
