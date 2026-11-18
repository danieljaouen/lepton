defmodule Lepton.Photon.WM.Classic do
  @moduledoc """
  The classic desktop: a Windows 95-style window manager for Photon.

  Grey 3D window frames with a navy title bar and minimize, maximize and
  close buttons; a teal desktop with icons (double-click to open); a
  taskbar with a Start button and menu, a button for each window (click
  to focus, again to minimize) and a clock. Ctrl+Esc opens the Start
  menu. Drawn with `Lepton.Photon.Canvas` and Lepton's own pixel art.
  """

  @behaviour Lepton.Photon.WM

  alias Lepton.Photon.{Canvas, Render}

  @face "#c0c0c0"
  @light "#dfdfdf"
  @white "#ffffff"
  @shadow "#808080"
  @dark "#000000"
  @navy "#000080"
  @inactive "#808080"
  @desktop "#008080"

  # frame: 4-pixel bevelled border, an 18-pixel title bar, 2 pixels of gap
  @border 4
  @title 18
  @top @border + @title + 2

  @taskbar 28
  @start_w 68
  @item_h 24
  @separator_h 8
  @menu_w 196
  @banner 22

  @menu [
    {"Firefox", :web, [app: "firefox", title: "Firefox"]},
    {"Terminal", :terminal, []},
    {"Text Editor", :editor, [command: "le", title: "Text Editor"]},
    {"System Monitor", :monitor, [command: "top", title: "System Monitor"]},
    {"Help", :help, [command: "help | less", title: "Help"]},
    :separator,
    {"Exit Desktop...", :exit, :quit}
  ]

  @icons [
    {"Firefox", :web, [app: "firefox", title: "Firefox"]},
    {"Terminal", :terminal, []},
    {"Text Editor", :editor, [command: "le", title: "Text Editor"]},
    {"System Monitor", :monitor, [command: "top", title: "System Monitor"]}
  ]

  @impl true
  def init(w, h), do: %{w: w, h: h, menu: false, hover: nil, selected: nil}

  # -- frames ----------------------------------------------------------------------------------

  @impl true
  def frame_size(w, h), do: {w + 2 * @border, h + @top + @border}

  @impl true
  def content_offset, do: {@border, @top}

  @impl true
  def frame_part(fw, fh, px, py) do
    by = @border + 2

    cond do
      px >= fw - 12 and py >= fh - 12 -> :corner
      py >= by and py < by + 14 and px >= fw - 22 and px < fw - 6 -> :close
      py >= by and py < by + 14 and px >= fw - 40 and px < fw - 24 -> :maximize
      py >= by and py < by + 14 and px >= fw - 56 and px < fw - 40 -> :minimize
      py < @top and py >= @border and px >= @border and px < fw - @border -> :title
      px < @border or px >= fw - @border or py < @border or py >= fh - @border -> :border
      py < @top -> :title
      true -> :content
    end
  end

  @impl true
  def decorations(title, fw, focused?, maximized?) do
    bar = Render.rgb(if focused?, do: @navy, else: @inactive)
    text = Render.rgb(if focused?, do: @white, else: @light)

    c =
      Canvas.new(fw, @top, Render.rgb(@face))
      |> edges(fw)
      |> Canvas.fill(@border, @border, fw - 2 * @border, @title, bar)
      |> Canvas.text(@border + 4, @border + 1, title || "", text, bar, bold: true, max_w: max(fw - 2 * @border - 64, 0))

    c =
      [{fw - 22, :close}, {fw - 40, if(maximized?, do: :restore, else: :maximize)}, {fw - 56, :minimize}]
      |> Enum.reduce(c, fn {x, glyph}, c -> c |> Canvas.bevel(x, @border + 2, 16, 14, :raised) |> button_glyph(x, @border + 2, glyph) end)

    Canvas.rows(c)
  end

  # The frame's top bevel (rows 0-1) and its sides down the rows given.
  defp edges(c, fw) do
    light = Render.rgb(@light)
    white = Render.rgb(@white)
    shadow = Render.rgb(@shadow)
    dark = Render.rgb(@dark)

    c
    |> Canvas.fill(0, 0, fw - 1, 1, light)
    |> Canvas.fill(fw - 1, 0, 1, c.h, dark)
    |> Canvas.fill(1, 1, fw - 3, 1, white)
    |> Canvas.fill(0, 1, 1, c.h - 1, light)
    |> Canvas.fill(1, 2, 1, c.h - 2, white)
    |> Canvas.fill(fw - 2, 1, 1, c.h - 1, shadow)
  end

  @impl true
  def frame_layer(x, y, cw, ch, rows, _focused?, content_row) do
    {fw, fh} = frame_size(cw, ch)
    px = &Render.rgb/1
    left = IO.iodata_to_binary([px.(@light), px.(@white), px.(@face), px.(@face)])
    right = IO.iodata_to_binary([px.(@face), px.(@face), px.(@shadow), px.(@dark)])
    plain = left <> :binary.copy(px.(@face), fw - 8) <> right
    above_bottom = px.(@light) <> :binary.copy(px.(@shadow), fw - 2) <> px.(@dark)
    bottom = :binary.copy(px.(@dark), fw)
    rows = List.to_tuple(rows)

    row = fn
      r when r < @top -> elem(rows, r)
      r when r == fh - 1 -> bottom
      r when r == fh - 2 -> above_bottom
      r when r >= fh - @border -> plain
      r -> <<left::binary, content_row.(r - @top)::binary, right::binary>>
    end

    %{x: x, y: y, w: fw, h: fh, row: row}
  end

  # -- the desktop -------------------------------------------------------------------------------

  @impl true
  def background(s) do
    row = :binary.copy(Render.rgb(@desktop), s.w)
    fn _y -> row end
  end

  @impl true
  def work_area(s), do: {0, 0, s.w, s.h - @taskbar}

  @impl true
  def signature(s, info) do
    {s.menu, s.hover, s.selected, s.w, s.h, clock(), Enum.map(info, &{&1.key, &1.title, &1.focused, &1.minimized})}
  end

  @impl true
  def layers(s, info) do
    icons =
      for {{label, kind, _}, i} <- Enum.with_index(@icons) do
        {x, y, w, h} = icon_rect(i)
        selected? = s.selected == i
        bg = Render.rgb(@desktop)

        c =
          Canvas.new(w, h, bg)
          |> icon(div(w - 32, 2), 2, kind, 32)
          |> label(label, w, 38, selected?)

        layer(c, x, y)
      end

    above = [taskbar(s, info)] ++ if(s.menu, do: [menu(s)], else: [])
    {icons, above}
  end

  defp label(c, text, w, y, selected?) do
    tw = min(Canvas.text_width(text), w)
    bg = Render.rgb(if selected?, do: @navy, else: @desktop)
    x = div(w - tw, 2)
    c |> Canvas.fill(x - 1, y, tw + 2, 16, bg) |> Canvas.text(x, y, text, Render.rgb(@white), bg, max_w: w)
  end

  defp icon_rect(i), do: {12, 12 + i * 76, 112, 56}

  defp layer(%Canvas{} = c, x, y) do
    rows = c.rows
    %{x: x, y: y, w: c.w, h: c.h, row: &elem(rows, &1)}
  end

  # -- the taskbar --------------------------------------------------------------------------------

  defp taskbar(s, info) do
    w = s.w
    face = Render.rgb(@face)

    c =
      Canvas.new(w, @taskbar, face)
      |> Canvas.fill(0, 0, w, 1, Render.rgb(@light))
      |> Canvas.fill(0, 1, w, 1, Render.rgb(@white))
      |> Canvas.bevel(2, 4, @start_w, 22, if(s.menu, do: :pressed, else: :raised))
      |> logo(6, 10)
      |> Canvas.text(23, 7, "Start", Render.rgb(@dark), face, bold: true)

    c =
      info
      |> task_buttons(w)
      |> Enum.reduce(c, fn {win, x, bw}, c ->
        active? = win.focused and not win.minimized

        c
        |> Canvas.bevel(x, 4, bw, 22, if(active?, do: :pressed, else: :raised))
        |> icon(x + 4, 7, :terminal, 16)
        |> Canvas.text(x + 24, 7, win.title || "", Render.rgb(@dark), face, bold: active?, max_w: bw - 28)
      end)

    time = clock()
    tw = Canvas.text_width(time)

    c
    |> Canvas.bevel(w - tw - 22, 4, tw + 18, 22, :thin_sunken)
    |> Canvas.text(w - tw - 13, 7, time, Render.rgb(@dark), face)
    |> layer(0, s.h - @taskbar)
  end

  # Task buttons: `{window, x, width}`.
  defp task_buttons([], _w), do: []

  defp task_buttons(info, w) do
    start = @start_w + 6
    avail = w - start - 100
    bw = min(160, div(avail, length(info)) - 4)
    for {win, i} <- Enum.with_index(info), do: {win, start + i * (bw + 4), bw}
  end

  defp clock do
    {_, {h, m, _}} = :calendar.local_time()
    {h12, ampm} = if h >= 12, do: {h - 12, "PM"}, else: {h, "AM"}
    "#{if h12 == 0, do: 12, else: h12}:#{String.pad_leading(to_string(m), 2, "0")} #{ampm}"
  end

  # -- the Start menu ------------------------------------------------------------------------------

  defp menu_height, do: Enum.reduce(@menu, 6, fn :separator, h -> h + @separator_h; _, h -> h + @item_h end)
  defp menu_rect(s), do: {2, s.h - @taskbar - menu_height() + 2, @menu_w, menu_height()}

  # Items with their y offsets within the menu.
  defp menu_items do
    {items, _} = Enum.map_reduce(@menu, 3, fn :separator, y -> {{:separator, y}, y + @separator_h}; item, y -> {{item, y}, y + @item_h} end)
    items
  end

  defp menu(s) do
    {x, y, w, h} = menu_rect(s)
    face = Render.rgb(@face)
    navy = Render.rgb(@navy)

    c =
      Canvas.new(w, h, face)
      |> Canvas.bevel(0, 0, w, h, :raised)
      |> Canvas.fill(3, 3, @banner, h - 6, Render.rgb(@shadow))

    banner = Canvas.vertical_text("Lepton", Render.rgb(@white), Render.rgb(@shadow))
    c = Canvas.blit(c, 3 + div(@banner - 16, 2), h - 3 - length(banner) - 4, banner)

    menu_items()
    |> Enum.with_index()
    |> Enum.reduce(c, fn
      {{:separator, iy}, _}, c ->
        c |> Canvas.fill(@banner + 5, iy + 3, w - @banner - 9, 1, Render.rgb(@shadow)) |> Canvas.fill(@banner + 5, iy + 4, w - @banner - 9, 1, Render.rgb(@white))

      {{{label, kind, _}, iy}, i}, c ->
        hover? = s.hover == i
        bg = if hover?, do: navy, else: face
        fg = Render.rgb(if hover?, do: @white, else: @dark)

        c
        |> Canvas.fill(@banner + 3, iy, w - @banner - 6, @item_h, bg)
        |> icon(@banner + 8, iy + 4, kind, 16)
        |> Canvas.text(@banner + 32, iy + 4, label, fg, bg)
    end)
    |> layer(x, y)
  end

  defp menu_hit(s, {px, py}) do
    {x, y, w, h} = menu_rect(s)

    if px >= x and px < x + w and py >= y and py < y + h do
      menu_items()
      |> Enum.with_index()
      |> Enum.find_value(:none, fn {{item, iy}, i} ->
        size = if item == :separator, do: @separator_h, else: @item_h
        if py >= y + iy and py < y + iy + size and item != :separator, do: {i, item}
      end)
    end
  end

  # -- input -----------------------------------------------------------------------------------------

  @impl true
  def click(s, info, {px, py} = pos, _button, double?) do
    on_bar? = py >= s.h - @taskbar

    cond do
      s.menu and menu_hit(s, pos) not in [nil, :none] ->
        {_, {_, _, action}} = menu_hit(s, pos)
        {:handled, %{s | menu: false, hover: nil}, [action_for(action)]}

      s.menu and menu_hit(s, pos) == :none ->
        {:handled, s, []}

      on_bar? and px >= 2 and px < 2 + @start_w ->
        {:handled, %{s | menu: not s.menu, hover: nil}, []}

      s.menu ->
        # Clicking anywhere else closes the menu, and the click goes on.
        click(%{s | menu: false, hover: nil}, info, pos, 0, double?)

      on_bar? ->
        case Enum.find(task_buttons(info, s.w), fn {_, x, bw} -> px >= x and px < x + bw end) do
          {win, _, _} when win.focused and not win.minimized -> {:handled, s, [{:minimize, win.key}]}
          {win, _, _} -> {:handled, s, [{:focus, win.key}]}
          nil -> {:handled, s, []}
        end

      true ->
        {:pass, %{s | selected: nil}, []}
    end
  end

  defp action_for(:quit), do: :quit
  defp action_for(opts), do: {:spawn, opts}

  @impl true
  def desktop_click(s, _info, {px, py}, double?) do
    hit =
      Enum.find(Enum.with_index(@icons), fn {_, i} ->
        {x, y, w, h} = icon_rect(i)
        px >= x and px < x + w and py >= y and py < y + h
      end)

    case hit do
      {{_, _, opts}, i} when double? -> {%{s | selected: i}, [{:spawn, opts}]}
      {_, i} -> {%{s | selected: i}, []}
      nil -> {%{s | selected: nil}, []}
    end
  end

  @impl true
  def motion(%{menu: true} = s, _info, pos) do
    case menu_hit(s, pos) do
      {i, _} -> %{s | hover: i}
      _ -> %{s | hover: nil}
    end
  end

  def motion(s, _info, _pos), do: s

  @impl true
  def menu(s, _info), do: %{s | menu: not s.menu, hover: if(s.menu, do: nil, else: 0)}

  # -- pixel art ---------------------------------------------------------------------------------------

  @glyphs %{
    close: {4, 3, ["kk    kk", " kk  kk ", "  kkkk  ", "   kk   ", "  kkkk  ", " kk  kk ", "kk    kk"]},
    maximize: {3, 2, ["kkkkkkkkk", "kkkkkkkkk", "k       k", "k       k", "k       k", "k       k", "k       k", "k       k", "kkkkkkkkk"]},
    minimize: {4, 9, ["kkkkkk", "kkkkkk"]},
    restore: {3, 2, ["  kkkkkk", "  kkkkkk", "  k    k", "kkkkkk k", "kkkkkk k", "k    kkk", "k    k  ", "k    k  ", "kkkkkk  "]}
  }

  defp button_glyph(c, x, y, glyph) do
    {dx, dy, art} = @glyphs[glyph]
    Canvas.art(c, x + dx, y + dy, art, %{"k" => @dark})
  end

  # Lepton's mark: a particle in its orbit.
  @logo [
    "    bbbbbb    ",
    "  bb      bb  ",
    " b          b ",
    "b     rr     b",
    "b    rrrr    b",
    "b    rrrr    b",
    "b     rr     b",
    " b          b ",
    "  bb      bb  ",
    "    bbbbbb    "
  ]

  defp logo(c, x, y), do: Canvas.art(c, x, y, @logo, %{"b" => @navy, "r" => "#c00000"})

  # Icons, drawn at 32 or 16 pixels.
  defp icon(c, x, y, :terminal, size) do
    s = div(size, 16)

    c
    |> Canvas.bevel(x, y, 16 * s, 12 * s, :raised)
    |> Canvas.fill(x + 2 * s, y + 2 * s, 12 * s, 8 * s, Render.rgb(@dark))
    |> then(fn c -> if size >= 32, do: Canvas.text(c, x + 6, y + 4, ">_", Render.rgb("#00ff00"), Render.rgb(@dark)), else: Canvas.fill(c, x + 3, y + 4, 4, 1, Render.rgb("#00ff00")) end)
    |> Canvas.fill(x + 5 * s, y + 12 * s, 6 * s, 2 * s, Render.rgb(@shadow))
    |> Canvas.fill(x + 3 * s, y + 14 * s, 10 * s, 2 * s, Render.rgb(@face))
  end

  defp icon(c, x, y, :editor, size) do
    s = div(size, 16)
    white = Render.rgb(@white)
    dark = Render.rgb(@dark)

    c =
      c
      |> Canvas.fill(x + 2 * s, y, 12 * s, 16 * s, dark)
      |> Canvas.fill(x + 2 * s + 1, y + 1, 12 * s - 2, 16 * s - 2, white)

    Enum.reduce(1..5, c, fn i, c -> Canvas.fill(c, x + 4 * s, y + (2 + 2 * i) * s, 8 * s, max(s - 1, 1), Render.rgb(@navy)) end)
  end

  defp icon(c, x, y, :monitor, size) do
    s = div(size, 16)

    c
    |> Canvas.bevel(x, y, 16 * s, 14 * s, :sunken, @white)
    |> Canvas.fill(x + 3 * s, y + 8 * s, 2 * s, 4 * s, Render.rgb("#c00000"))
    |> Canvas.fill(x + 6 * s, y + 4 * s, 2 * s, 8 * s, Render.rgb("#008000"))
    |> Canvas.fill(x + 9 * s, y + 6 * s, 2 * s, 6 * s, Render.rgb(@navy))
    |> Canvas.fill(x + 12 * s, y + 3 * s, 2 * s, 9 * s, Render.rgb("#808000"))
  end

  # A globe (for the web browser).
  @globe [
    "     bbbbbb     ",
    "   bbggbbbbbb   ",
    "  bggggbbbbggb  ",
    " bbggggbbbgggbb ",
    " bbbgggbbbbggbb ",
    "bbbbggbbbbbbbbbb",
    "bbbbbgbbbbggbbbb",
    "bbbbbbbbbggggbbb",
    "bbbbbbbbbbgggbbb",
    "bbggbbbbbbbggbbb",
    " bgggbbbbbbbgbb ",
    " bbgggbbbbbbbbb ",
    "  bbggbbbbbbbb  ",
    "   bbbbbbbbbb   ",
    "     bbbbbb     "
  ]

  defp icon(c, x, y, :web, size) do
    s = div(size, 16)
    art = for row <- @globe, line = Enum.map_join(String.graphemes(row), &String.duplicate(&1, s)), _ <- 1..s, do: line
    Canvas.art(c, x, y, art, %{"b" => "#2060c0", "g" => "#30a030"})
  end

  defp icon(c, x, y, :help, size) do
    s = div(size, 16)

    c
    |> Canvas.fill(x + 2 * s, y + 1 * s, 12 * s, 14 * s, Render.rgb(@navy))
    |> Canvas.text(x + 4 * s, y, "?", Render.rgb(@white), Render.rgb(@navy), bold: true)
  end

  defp icon(c, x, y, :exit, size) do
    s = div(size, 16)

    c
    |> Canvas.bevel(x + 2 * s, y + 1 * s, 12 * s, 14 * s, :raised)
    |> Canvas.fill(x + 6 * s, y + 4 * s, 4 * s, 8 * s, Render.rgb(@dark))
  end
end
