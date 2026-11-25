defmodule Lepton.Photon.WM.Classic do
  @moduledoc """
  The classic desktop: a Windows 95-style window manager for Photon.

  Grey 3D window frames with a navy title bar and minimize, maximize and
  close buttons; a teal desktop with icons (double-click to open); a
  taskbar with a Start button and menu, a button for each window (click
  to focus, again to minimize), a tray (Wi-Fi, Bluetooth, the volume,
  an emoji picker) and a clock. Ctrl+Esc opens the Start menu. Drawn with `Lepton.Photon.Canvas` and Lepton's own pixel art.
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
    {"Typst Editor", :typst, [command: "le --typst", title: "Typst Editor"]},
    {"System Monitor", :monitor, [command: "top", title: "System Monitor"]},
    {"Media Player", :media, [command: "play", title: "Media Player"]},
    {"Radio", :radio, [command: "radio", title: "Radio"]},
    {"Torrents", :torrent, [command: "torrent", title: "Torrents"]},
    {"Printers", :printer, [command: "printers; read -p 'Press Enter to close. ' x", title: "Printers"]},
    {"Passwords", :vault, [vault: true, title: "Passwords"]},
    {"Help", :help, [command: "help | less", title: "Help"]},
    :separator,
    {"Exit Desktop...", :exit, :quit}
  ]

  @icons [
    {"Firefox", :web, [app: "firefox", title: "Firefox"]},
    {"Terminal", :terminal, []},
    {"Text Editor", :editor, [command: "le", title: "Text Editor"]},
    {"Typst Editor", :typst, [command: "le --typst", title: "Typst Editor"]},
    {"System Monitor", :monitor, [command: "top", title: "System Monitor"]},
    {"Media Player", :media, [command: "play", title: "Media Player"]},
    {"Radio", :radio, [command: "radio", title: "Radio"]},
    {"Torrents", :torrent, [command: "torrent", title: "Torrents"]},
    {"Passwords", :vault, [vault: true, title: "Passwords"]}
  ]

  @impl true
  # The taskbar is on the primary display (`bar_w` wide); the desktop may extend past it.
  def init(w, h, {pw, _ph}), do: %{w: w, h: h, bar_w: pw, menu: false, hover: nil, selected: nil, volume: false, wifi: false, bluetooth: false, emoji: nil}

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
    {s.menu, s.hover, s.selected, s.volume, s.wifi, s.bluetooth, s.emoji, s.w, s.h, s.bar_w, clock(), Lepton.Media.mounted(), sound(), Lepton.Wifi.summary(), Lepton.Bluetooth.summary(), Lepton.Keyboard.state(), Lepton.Postgres.installed?(), Enum.map(info, &{&1.key, &1.title, &1.focused, &1.minimized})}
  end

  @impl true
  def layers(s, info) do
    icons =
      for {{label, kind, _}, i} <- Enum.with_index(icons()) do
        {x, y, w, h} = icon_rect(i, s.h)
        selected? = s.selected == i
        bg = Render.rgb(@desktop)

        c =
          Canvas.new(w, h, bg)
          |> icon(div(w - 32, 2), 2, kind, 32)
          |> label(label, w, 38, selected?)

        layer(c, x, y)
      end

    above =
      [taskbar(s, info)] ++
        if(s.menu, do: [menu(s)], else: []) ++ if(s.volume, do: [volume_popup(s)], else: []) ++ if(s.wifi, do: [wifi_popup(s)], else: []) ++ if(s.bluetooth, do: [bt_popup(s)], else: []) ++
        if(s.emoji, do: [emoji_popup(s)], else: [])
    {icons, above}
  end

  # The desktop's icons: the apps, then a drive for each USB drive or SD
  # card that is mounted (Lepton.Media), which opens a terminal there.
  defp icons do
    drives = for m <- Lepton.Media.mounted(), name = Path.basename(m.dir), do: {name, :drive, [title: name, cwd: m.dir]}
    @icons ++ [postgres_icon()] ++ drives
  end

  # PostgreSQL: "Install PostgreSQL" until it is (installs it, creates the
  # database and starts the service), then psql on it.
  defp postgres_icon do
    if Lepton.Postgres.installed?(),
      do: {"PostgreSQL", :database, [command: "psql", title: "PostgreSQL"]},
      else: {"Install PostgreSQL", :database, [command: "sudo postgresql setup; read -p 'Press Enter to close. ' x", title: "Install PostgreSQL"]}
  end

  defp label(c, text, w, y, selected?) do
    tw = min(Canvas.text_width(text), w)
    bg = Render.rgb(if selected?, do: @navy, else: @desktop)
    x = div(w - tw, 2)
    c |> Canvas.fill(x - 1, y, tw + 2, 16, bg) |> Canvas.text(x, y, text, Render.rgb(@white), bg, max_w: w)
  end

  # Down the left, then (a column full above the taskbar) the next column.
  @doc false
  def icon_rect(i, h) do
    rows = max(div(h - @taskbar - 12, 76), 1)
    {12 + div(i, rows) * 120, 12 + rem(i, rows) * 76, 112, 56}
  end

  defp layer(%Canvas{} = c, x, y) do
    rows = c.rows
    %{x: x, y: y, w: c.w, h: c.h, row: &elem(rows, &1)}
  end

  # -- the taskbar --------------------------------------------------------------------------------

  defp taskbar(s, info) do
    w = s.bar_w
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

    # The tray: the input source (with more than one), Wi-Fi (with Wi-Fi
    # hardware), Bluetooth, the volume's speaker, the emoji picker and the clock.
    tray = tray(s)
    %{muted: muted} = sound()
    wifi = Lepton.Wifi.summary()

    c
    |> Canvas.bevel(tray.x, 4, w - tray.x - 4, 22, :thin_sunken)
    |> then(&if(tray.keyboard, do: Canvas.text(&1, tray.keyboard, 7, keyboard_label(), Render.rgb(@dark), face), else: &1))
    |> then(&if(tray.wifi, do: wifi_icon(&1, tray.wifi, 8, if(wifi.ssid, do: Lepton.Wifi.bars(wifi.signal) |> max(1), else: 0)), else: &1))
    |> then(&if(tray.bluetooth, do: bt_icon(&1, tray.bluetooth + 2, 7, bt_on?()), else: &1))
    |> speaker(tray.speaker, 7, muted)
    |> smiley(tray.emoji, 7, s.emoji != nil)
    |> Canvas.text(w - Canvas.text_width(clock()) - 13, 7, clock(), Render.rgb(@dark), face)
    |> layer(0, s.h - @taskbar)
  end

  # Where the tray starts and its icons are (taskbar x coordinates).
  @doc false
  def tray(s) do
    # (each icon only with its hardware: Wi-Fi, a Bluetooth adapter)
    icons =
      Enum.filter(
        [keyboard: length(Lepton.Keyboard.state().sources) > 1, wifi: Lepton.Wifi.summary().iface != nil, bluetooth: Lepton.Bluetooth.summary().controllers != []],
        &elem(&1, 1)
      )

    x = s.bar_w - Canvas.text_width(clock()) - 62 - 20 * length(icons)
    at = icons |> Enum.with_index() |> Map.new(fn {{name, _}, i} -> {name, x + 4 + 20 * i} end)
    %{x: x, keyboard: at[:keyboard], wifi: at[:wifi], bluetooth: at[:bluetooth], speaker: x + 4 + 20 * length(icons), emoji: x + 24 + 20 * length(icons)}
  end

  # The input source: EN, KO (Hangul; "A" when Korean types English), TH, ...
  defp keyboard_label do
    case Lepton.Keyboard.state() do
      %{current: "ko", hangul: false} -> "A"
      %{current: id} -> Lepton.Keyboard.label(id)
    end
  end

  @rune ["  kk  ", "  k k ", "k k  k", " kk k ", "  kk  ", " kk k ", "k k  k", "  k k ", "  kk  "]

  # Bluetooth's rune: navy when the radio is on, grey when not.
  defp bt_icon(c, x, y, on?), do: Canvas.art(c, x, y + 2, Enum.map(@rune, &String.replace(&1, "k", "kk")), %{"k" => if(on?, do: @navy, else: @shadow)})

  defp bt_on?, do: match?(%{adapter: %{powered: true}}, Lepton.Bluetooth.summary())

  # Signal bars: `level` of 4 in `color`, the rest grey.
  defp wifi_icon(c, x, y, level, color \\ @dark) do
    Enum.reduce(1..4, c, fn i, c ->
      h = 3 * i
      Canvas.fill(c, x + (i - 1) * 4, y + 12 - h, 3, h, Render.rgb(if i <= level, do: color, else: @shadow))
    end)
  end

  defp sound, do: Map.take(Lepton.Sound.status(), [:volume, :muted])

  @speaker [
    "      kk      ",
    "     kwk   b  ",
    "kkkkkwwk b  b ",
    "kwwwwwwk  b  b",
    "kwwwwwwk  b  b",
    "kwwwwwwk  b  b",
    "kkkkkwwk b  b ",
    "     kwk   b  ",
    "      kk      "
  ]

  @speaker_muted [
    "      kk      ",
    "     kwk      ",
    "kkkkkwwk r  r ",
    "kwwwwwwk  rr  ",
    "kwwwwwwk  rr  ",
    "kwwwwwwk r  r ",
    "kkkkkwwk      ",
    "     kwk      ",
    "      kk      "
  ]

  defp speaker(c, x, y, muted?),
    do: Canvas.art(c, x, y + 3, if(muted?, do: @speaker_muted, else: @speaker), %{"k" => @dark, "w" => @white, "b" => @navy, "r" => "#c00000"})

  # -- Wi-Fi networks (click the signal bars) ----------------------------------------------------------

  @wifi_w 300
  @row_h 20
  @max_rows 10

  @lock ["  kkk  ", " k   k ", " k   k ", "kkkkkkk", "kkk kkk", "kkk kkk", "kkkkkkk"]

  @doc false
  # The network list's layout, in screen coordinates: `%{rect, rows:
  # [{network, rect}], list, status_y, refresh}`.
  def wifi_layout(s) do
    wifi = Lepton.Wifi.summary()
    nets = Enum.take(wifi.networks, @max_rows)
    list_h = max(length(nets), 1) * @row_h + 4
    status_y = 26 + list_h + 8
    h = status_y + 20 + 22 + 8
    x = min((tray(s).wifi || s.bar_w) - 120, s.bar_w - @wifi_w - 2)
    y = s.h - @taskbar - h
    rows = for {n, i} <- Enum.with_index(nets), do: {n, {x + 8, y + 28 + i * @row_h, @wifi_w - 16, @row_h}}
    %{rect: {x, y, @wifi_w, h}, rows: rows, list: {6, 26, @wifi_w - 12, list_h}, status_y: status_y, refresh: {x + @wifi_w - 80, y + status_y + 20, 72, 22}, wifi: wifi}
  end

  defp wifi_popup(s) do
    %{rect: {x, y, w, h}, rows: rows, list: {lx, ly, lw, lh}, status_y: sy, refresh: {rx, ry, rw, rh}, wifi: wifi} = wifi_layout(s)
    face = Render.rgb(@face)
    dark = Render.rgb(@dark)
    white = Render.rgb(@white)
    navy = Render.rgb(@navy)

    c =
      Canvas.new(w, h, face)
      |> Canvas.bevel(0, 0, w, h, :raised)
      |> Canvas.text(8, 6, "Wireless Networks", dark, face, bold: true)
      |> Canvas.bevel(lx, ly, lw, lh, :sunken, @white)

    c =
      if rows == [] do
        Canvas.text(c, lx + 8, ly + 4, if(wifi.scanning, do: "Looking for networks...", else: "No networks found"), Render.rgb(@shadow), white)
      else
        Enum.reduce(rows, c, fn {n, {_, ny, _, _}}, c ->
          here? = n.ssid == wifi.ssid
          {fg, bg} = if here?, do: {white, navy}, else: {dark, white}
          ry0 = ny - y

          c
          |> Canvas.fill(lx + 2, ry0, lw - 4, @row_h, bg)
          |> wifi_icon(lx + 6, ry0 + 4, Lepton.Wifi.bars(n.signal), if(here?, do: @white, else: @dark))
          |> Canvas.text(lx + 26, ry0 + 2, n.ssid, fg, bg, bold: here?, max_w: lw - 56)
          |> then(&if(n.security != "open", do: Canvas.art(&1, lx + lw - 16, ry0 + 6, @lock, %{"k" => if(here?, do: @white, else: @dark)}), else: &1))
        end)
      end

    status =
      cond do
        wifi.ssid && wifi.ip -> "Connected to #{wifi.ssid} (#{wifi.ip})"
        wifi.ssid -> "Connected to #{wifi.ssid} (no address yet)"
        wifi.state in ["ASSOCIATING", "ASSOCIATED", "AUTHENTICATING", "4WAY_HANDSHAKE", "GROUP_HANDSHAKE"] -> "Connecting..."
        true -> "Not connected: click a network."
      end

    c
    |> Canvas.text(8, sy, status, dark, face, max_w: w - 16)
    |> Canvas.bevel(rx - x, ry - y, rw, rh, :raised)
    |> Canvas.text(rx - x + div(rw - Canvas.text_width("Refresh"), 2), ry - y + 3, "Refresh", dark, face)
    |> layer(x, y)
  end

  # A click in the network list: a network to join (in a terminal, which
  # asks for its passphrase), Refresh, or outside it.
  defp wifi_click(s, {px, py}) do
    %{rect: rect, rows: rows, refresh: refresh, wifi: wifi} = wifi_layout(s)
    inside? = fn {x, y, w, h} -> px >= x and px < x + w and py >= y and py < y + h end

    cond do
      not inside?.(rect) ->
        :outside

      inside?.(refresh) ->
        Lepton.Wifi.scan_async()

      row = Enum.find(rows, fn {_, r} -> inside?.(r) end) ->
        {n, _} = row
        if n.ssid == wifi.ssid, do: :ok, else: {:join, [wifi: n.ssid, open: n.security == "open", title: "Wi-Fi: #{n.ssid}"]}

      true ->
        :ok
    end
  end

  # -- Bluetooth devices (click the rune) ------------------------------------------------------------------

  @bt_w 340

  @doc false
  # The device list's layout, in screen coordinates: `%{rect, rows:
  # [{device, rect}], list, status_y, button, bt}`.
  def bt_layout(s) do
    bt = Lepton.Bluetooth.summary()
    devices = Enum.take(bt.devices, @max_rows)
    list_h = max(length(devices), 1) * @row_h + 4
    status_y = 26 + list_h + 8
    h = status_y + 20 + 22 + 8
    x = min((tray(s).bluetooth || s.bar_w) - 140, s.bar_w - @bt_w - 2)
    y = s.h - @taskbar - h
    rows = for {d, i} <- Enum.with_index(devices), do: {d, {x + 8, y + 28 + i * @row_h, @bt_w - 16, @row_h}}
    %{rect: {x, y, @bt_w, h}, rows: rows, list: {6, 26, @bt_w - 12, list_h}, status_y: status_y, button: {x + @bt_w - 100, y + status_y + 20, 92, 22}, bt: bt}
  end

  defp bt_popup(s) do
    %{rect: {x, y, w, h}, rows: rows, list: {lx, ly, lw, lh}, status_y: sy, button: {bx, by, bw, bh}, bt: bt} = bt_layout(s)
    face = Render.rgb(@face)
    dark = Render.rgb(@dark)
    white = Render.rgb(@white)
    grey = Render.rgb(@shadow)

    c =
      Canvas.new(w, h, face)
      |> Canvas.bevel(0, 0, w, h, :raised)
      |> Canvas.text(8, 6, "Bluetooth Devices", dark, face, bold: true)
      |> Canvas.bevel(lx, ly, lw, lh, :sunken, @white)

    c =
      if rows == [] do
        Canvas.text(c, lx + 8, ly + 4, bt_empty(bt), grey, white, max_w: lw - 16)
      else
        Enum.reduce(rows, c, fn {d, {_, ry, _, _}}, c ->
          {fg, bg} = if d.connected, do: {white, Render.rgb(@navy)}, else: {dark, white}
          state = cond do
            d.connected -> "connected"
            d.paired -> "paired"
            true -> "new"
          end

          r = ry - y

          c
          |> Canvas.fill(lx + 2, r, lw - 4, @row_h, bg)
          # name | kind | state, right-aligned
          |> Canvas.text(lx + 6, r + 2, d.name, fg, bg, bold: d.connected, max_w: lw - 172)
          |> Canvas.text(lx + lw - 162, r + 2, "#{d.kind}", if(d.connected, do: white, else: grey), bg, max_w: 80)
          |> then(&Canvas.text(&1, lx + lw - Canvas.text_width(state) - 8, r + 2, state, fg, bg))
        end)
      end

    status =
      cond do
        not bt.installed -> "Bluetooth isn't installed yet."
        bt.adapter == nil -> "Starting Bluetooth..."
        not bt.adapter.powered -> "Bluetooth is off."
        bt.adapter.discovering -> "Looking for devices nearby..."
        true -> "Click a device to pair, connect or disconnect it."
      end

    label = bt_button(bt)

    c
    |> Canvas.text(8, sy, status, dark, face, max_w: w - 16)
    |> Canvas.bevel(bx - x, by - y, bw, bh, :raised)
    |> Canvas.text(bx - x + div(bw - Canvas.text_width(label), 2), by - y + 3, label, dark, face)
    |> layer(x, y)
  end

  defp bt_empty(%{installed: false}), do: "Install Bluetooth to use it."
  defp bt_empty(%{adapter: %{powered: false}}), do: "Turn Bluetooth on to find devices."
  defp bt_empty(_), do: "No devices yet: put yours in pairing mode."

  defp bt_button(%{installed: false}), do: "Install"
  defp bt_button(%{adapter: %{powered: false}}), do: "Turn on"
  defp bt_button(_), do: "Turn off"

  # A click in the device list: a device (pair, connect or disconnect it,
  # in a terminal), the button, or outside it.
  defp bt_click(s, {px, py}) do
    %{rect: rect, rows: rows, button: button, bt: bt} = bt_layout(s)
    inside? = fn {x, y, w, h} -> px >= x and px < x + w and py >= y and py < y + h end

    cond do
      not inside?.(rect) ->
        :outside

      inside?.(button) ->
        args = case bt_button(bt) do
          "Install" -> ["install"]
          "Turn on" -> ["on"]
          _ -> ["off"]
        end

        {:run, [bluetooth: args, title: "Bluetooth"]}

      row = Enum.find(rows, fn {_, r} -> inside?.(r) end) ->
        {d, _} = row
        action = cond do
          d.connected -> "disconnect"
          d.paired -> "connect"
          true -> "pair"
        end

        {:run, [bluetooth: [action, d.address], title: "Bluetooth: #{d.name}"]}

      true ->
        :ok
    end
  end

  # -- the volume control (click the speaker) ------------------------------------------------------------

  @vol_w 64
  @vol_h 196
  @track_top 34
  @track_h 100

  defp volume_rect(s) do
    x = min(tray(s).speaker - div(@vol_w, 2) + 8, s.bar_w - @vol_w - 2)
    {x, s.h - @taskbar - @vol_h, @vol_w, @vol_h}
  end

  defp volume_popup(s) do
    {x, y, w, h} = volume_rect(s)
    %{volume: volume, muted: muted} = sound()
    face = Render.rgb(@face)
    dark = Render.rgb(@dark)
    cx = div(w, 2)
    thumb_y = @track_top + @track_h - round(volume * @track_h / 100)

    c =
      Canvas.new(w, h, face)
      |> Canvas.bevel(0, 0, w, h, :raised)
      |> Canvas.text(div(w - Canvas.text_width("Volume"), 2), 8, "Volume", dark, face, bold: true)
      |> Canvas.bevel(cx - 2, @track_top - 2, 4, @track_h + 4, :sunken)

    c =
      Enum.reduce(0..10, c, fn i, c -> Canvas.fill(c, cx + 10, @track_top + div(i * @track_h, 10), if(rem(i, 5) == 0, do: 6, else: 3), 1, dark) end)
      |> Canvas.bevel(cx - 11, thumb_y - 5, 22, 10, :raised)
      |> Canvas.text(div(w - Canvas.text_width("#{volume}%"), 2), @track_top + @track_h + 8, "#{volume}%", dark, face)

    # The Mute box.
    by = h - 26

    c =
      c
      |> Canvas.bevel(8, by, 13, 13, :sunken, @white)
      |> Canvas.text(26, by - 2, "Mute", dark, face)

    c = if muted, do: Canvas.art(c, 10, by + 3, ["      k", "     kk", "k   kk ", "kk kk  ", " kkk   ", "  k    "], %{"k" => @dark}), else: c
    layer(c, x, y)
  end

  # A click in the volume control: on the slider sets the volume, on the box mutes.
  defp volume_click(s, {px, py}) do
    {x, y, w, h} = volume_rect(s)
    {rx, ry} = {px - x, py - y}

    cond do
      rx < 0 or ry < 0 or rx >= w or ry >= h -> :outside
      ry >= @track_top - 6 and ry <= @track_top + @track_h + 6 -> Lepton.Sound.set_volume((@track_top + @track_h - ry) * 100 / @track_h)
      ry >= h - 28 -> Lepton.Sound.mute(:toggle)
      true -> :ok
    end
  end

  # -- emoji (click the smiley) -------------------------------------------------------------------------


  # Single code points with emoji presentation (no variation selectors or
  # joiners, so every program takes them as typed), drawn with Unifont's
  # glyphs (Lepton.Wayland.Font): {category, emoji}.
  @emoji (
           cps = fn ranges -> Enum.flat_map(ranges, fn %Range{} = r -> Enum.to_list(r); cp -> [cp] end) end

           [
             {"Smileys", cps.([0x1F600..0x1F637, 0x1F641..0x1F644])},
             {"People", cps.([0x1F44A..0x1F450, 0x1F446..0x1F449, 0x1F64B..0x1F64F, 0x1F466..0x1F478, 0x1F47B..0x1F480, 0x1F4AA, 0x1F440, 0x1F442..0x1F445, 0x1F919..0x1F91F])},
             {"Nature", cps.([0x1F40C..0x1F43C, 0x1F331..0x1F335, 0x1F337..0x1F33C])},
             {"Food", cps.([0x1F345..0x1F37C, 0x1F950..0x1F953])},
             {"Activities", cps.([0x1F380..0x1F393, 0x1F3A0..0x1F3C7])},
             {"Travel", cps.([0x1F680..0x1F68E, 0x1F690..0x1F6A4, 0x1F3E0..0x1F3F0, 0x1F30D..0x1F30F, 0x1F319, 0x1F31F, 0x1F308, 0x1F30B])},
             {"Objects", cps.([0x1F4BB..0x1F4F6])},
             {"Symbols", cps.([0x1F493..0x1F4AF, 0x1F534..0x1F53D, 0x1F7E0..0x1F7EA, 0x1F191..0x1F19A])}
           ]
           |> Enum.map(fn {name, list} -> {name, Enum.map(list, &<<&1::utf8>>)} end)
         )

  @doc false
  def emoji, do: @emoji

  # each category's tab shows one of its own
  @tab_icons ["😀", "👋", "🐶", "🍕", "🎉", "🚀", "💡", "💯"]

  @emoji_cols 10
  @emoji_rows 6
  @cell 24
  @tab_w 28
  @emoji_w 2 * 8 + @emoji_cols * @cell
  @grid_top 54
  @emoji_h @grid_top + @emoji_rows * @cell + 4 + 6 + 20 + 6

  @doc false
  def emoji_rect(s) do
    x = min(tray(s).emoji - div(@emoji_w, 2) + 8, s.bar_w - @emoji_w - 2)
    {x, s.h - @taskbar - @emoji_h, @emoji_w, @emoji_h}
  end

  @doc false
  # What a point of the picker is: `{:tab, i}`, `{:cell, i, emoji}`,
  # `:inside` or `:outside` (screen coordinates).
  def emoji_hit(s, {px, py}) do
    {x, y, w, h} = emoji_rect(s)
    {rx, ry} = {trunc(px - x), trunc(py - y)}
    {_, list} = Enum.at(@emoji, s.emoji.tab)

    cond do
      rx < 0 or ry < 0 or rx >= w or ry >= h ->
        :outside

      ry >= 26 and ry < 50 and rx >= 8 and rx < 8 + length(@emoji) * @tab_w ->
        {:tab, div(rx - 8, @tab_w)}

      ry >= @grid_top + 2 and ry < @grid_top + 2 + @emoji_rows * @cell and rx >= 8 and rx < 8 + @emoji_cols * @cell ->
        i = div(ry - @grid_top - 2, @cell) * @emoji_cols + div(rx - 8, @cell)
        if e = Enum.at(list, i), do: {:cell, i, e}, else: :inside

      true ->
        :inside
    end
  end

  # A click in the picker: a tab shows its category, an emoji is typed.
  defp emoji_click(s, pos) do
    case emoji_hit(s, pos) do
      {:cell, _, e} -> {:type, e}
      other -> other
    end
  end

  defp emoji_popup(s) do
    {x, y, w, h} = emoji_rect(s)
    %{tab: tab, hover: hover, status: status} = s.emoji
    {name, list} = Enum.at(@emoji, tab)
    face = Render.rgb(@face)
    dark = Render.rgb(@dark)
    white = Render.rgb(@white)
    navy = Render.rgb(@navy)

    c =
      Canvas.new(w, h, face)
      |> Canvas.bevel(0, 0, w, h, :raised)
      |> Canvas.text(8, 6, "Emoji: #{name}", dark, face, bold: true)

    c =
      @tab_icons
      |> Enum.with_index()
      |> Enum.reduce(c, fn {icon, i}, c ->
        tx = 8 + i * @tab_w

        c
        |> Canvas.bevel(tx, 26, @tab_w - 2, 24, if(i == tab, do: :pressed, else: :raised))
        |> Canvas.text(tx + 5, 30, icon, dark, face)
      end)
      |> Canvas.bevel(6, @grid_top, w - 12, @emoji_rows * @cell + 4, :sunken, @white)

    c =
      list
      |> Enum.take(@emoji_cols * @emoji_rows)
      |> Enum.with_index()
      |> Enum.reduce(c, fn {e, i}, c ->
        {cx, cy} = {8 + rem(i, @emoji_cols) * @cell, @grid_top + 2 + div(i, @emoji_cols) * @cell}
        {fg, bg} = if i == hover, do: {white, navy}, else: {dark, white}

        c
        |> Canvas.fill(cx, cy, @cell, @cell, bg)
        |> Canvas.text(cx + 4, cy + 4, e, fg, bg)
      end)

    line =
      cond do
        e = hover && Enum.at(list, hover) -> "#{e}  U+#{e |> String.to_charlist() |> hd() |> Integer.to_string(16)}"
        status -> status
        true -> "Click one to type it."
      end

    c
    |> Canvas.text(8, @grid_top + @emoji_rows * @cell + 4 + 6, line, dark, face, max_w: w - 16)
    |> layer(x, y)
  end

  @smiley [
    "    kkkkkk    ",
    "  kkyyyyyykk  ",
    " kyyyyyyyyyyk ",
    " kyyyyyyyyyyk ",
    "kyyykyyyykyyyk",
    "kyyykyyyykyyyk",
    "kyyyyyyyyyyyyk",
    "kyykyyyyyykyyk",
    "kyyykyyyykyyyk",
    " kyyykkkkyyyk ",
    " kyyyyyyyyyyk ",
    "  kkyyyyyykk  ",
    "    kkkkkk    "
  ]

  # The picker's smiley: yellow, sunk in while the picker is open.
  defp smiley(c, x, y, open?) do
    c = if open?, do: Canvas.bevel(c, x - 2, y - 1, 18, 18, :thin_sunken), else: c
    Canvas.art(c, x, y + 1, @smiley, %{"k" => @dark, "y" => "#ffd800"})
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
    {_, {h, m, _}} = Lepton.Time.erl()
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
    on_bar? = py >= s.h - @taskbar and px < s.bar_w
    tray = tray(s)
    on_speaker? = on_bar? and px >= tray.speaker - 2 and px < tray.speaker + 18
    on_wifi? = on_bar? and tray.wifi != nil and px >= tray.wifi - 2 and px < tray.wifi + 18
    on_bt? = on_bar? and tray.bluetooth != nil and px >= tray.bluetooth - 2 and px < tray.bluetooth + 18
    on_keyboard? = on_bar? and tray.keyboard != nil and px >= tray.keyboard - 2 and px < tray.keyboard + 18
    on_emoji? = on_bar? and px >= tray.emoji - 2 and px < tray.emoji + 18

    cond do
      # The input source: the next one (Photon hears of it and tells the programs).
      on_keyboard? ->
        _ = Lepton.Keyboard.next()
        {:handled, %{s | volume: false, wifi: false, bluetooth: false, emoji: nil, menu: false, hover: nil}, []}

      on_speaker? ->
        {:handled, %{s | volume: not s.volume, wifi: false, bluetooth: false, emoji: nil, menu: false, hover: nil}, []}

      on_emoji? ->
        emoji = if s.emoji, do: nil, else: %{tab: 0, hover: nil, status: nil}
        {:handled, %{s | emoji: emoji, volume: false, wifi: false, bluetooth: false, menu: false, hover: nil}, []}

      s.emoji ->
        case emoji_click(s, pos) do
          :outside -> click(%{s | emoji: nil}, info, pos, 0, double?)
          {:tab, i} -> {:handled, %{s | emoji: %{s.emoji | tab: i, hover: nil, status: nil}}, []}
          {:type, e} -> {:handled, s, [{:type, e}]}
          _ -> {:handled, s, []}
        end

      on_bt? ->
        # Opening the list looks for devices nearby.
        # (from a process of its own: the desktop never waits for Bluetooth)
        if not s.bluetooth, do: spawn(fn -> Lepton.Bluetooth.discover(30) end)
        {:handled, %{s | bluetooth: not s.bluetooth, wifi: false, volume: false, emoji: nil, menu: false, hover: nil}, []}

      s.bluetooth ->
        case bt_click(s, pos) do
          :outside -> click(%{s | bluetooth: false}, info, pos, 0, double?)
          {:run, opts} -> {:handled, %{s | bluetooth: false}, [{:spawn, opts}]}
          _ -> {:handled, s, []}
        end

      on_wifi? ->
        # Opening the list looks for networks again.
        if not s.wifi, do: Lepton.Wifi.scan_async()
        {:handled, %{s | wifi: not s.wifi, bluetooth: false, volume: false, emoji: nil, menu: false, hover: nil}, []}

      s.wifi ->
        case wifi_click(s, pos) do
          :outside -> click(%{s | wifi: false}, info, pos, 0, double?)
          {:join, opts} -> {:handled, %{s | wifi: false}, [{:spawn, opts}]}
          _ -> {:handled, s, []}
        end

      s.volume and volume_click(s, pos) != :outside ->
        {:handled, s, []}

      s.volume ->
        # Clicking elsewhere closes it, and the click goes on.
        click(%{s | volume: false}, info, pos, 0, double?)

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
        case Enum.find(task_buttons(info, s.bar_w), fn {_, x, bw} -> px >= x and px < x + bw end) do
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
      Enum.find(Enum.with_index(icons()), fn {_, i} ->
        {x, y, w, h} = icon_rect(i, s.h)
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

  def motion(%{emoji: %{} = e} = s, _info, pos) do
    hover = case emoji_hit(s, pos) do {:cell, i, _} -> i; _ -> nil end
    if hover == e.hover, do: s, else: %{s | emoji: %{e | hover: hover}}
  end

  def motion(s, _info, _pos), do: s

  @impl true
  # What became of an emoji clicked in the picker (Photon tells).
  def typed(%{emoji: %{} = e} = s, how, text) do
    status = if how == :typed, do: "Typed #{text}", else: "Copied #{text}: paste it."
    %{s | emoji: %{e | status: status}}
  end

  def typed(s, _how, _text), do: s

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

  # A printer: grey body, paper coming out of the top and the tray.
  defp icon(c, x, y, :printer, size) do
    s = div(size, 16)

    c
    |> Canvas.fill(x + 4 * s, y + 1 * s, 8 * s, 5 * s, Render.rgb(@white))
    |> Canvas.bevel(x, y + 5 * s, 16 * s, 7 * s, :raised)
    |> Canvas.fill(x + 12 * s, y + 7 * s, 2 * s, 1 * s, Render.rgb("#008000"))
    |> Canvas.fill(x + 3 * s, y + 11 * s, 10 * s, 4 * s, Render.rgb(@white))
    |> Canvas.fill(x + 5 * s, y + 12 * s, 6 * s, 1 * s, Render.rgb(@shadow))
  end

  # A play button on a film frame (the media player).
  defp icon(c, x, y, :media, size) do
    s = div(size, 16)
    dark = Render.rgb(@dark)

    c =
      c
      |> Canvas.fill(x, y + 2 * s, 16 * s, 12 * s, dark)
      |> Canvas.fill(x + 2 * s, y + 4 * s, 12 * s, 8 * s, Render.rgb("#1f4e9c"))

    # the triangle, a column at a time
    Enum.reduce(0..4, c, fn i, c -> Canvas.fill(c, x + (6 + i) * s, y + (5 + div(i, 2)) * s, s, (6 - 2 * div(i, 2)) * s, Render.rgb(@white)) end)
  end

  # A radio: a box, its speaker and dial, an aerial.
  defp icon(c, x, y, :radio, size) do
    s = div(size, 16)
    dark = Render.rgb(@dark)

    c
    |> Canvas.fill(x + 10 * s, y, s, 5 * s, dark)
    |> Canvas.fill(x, y + 5 * s, 16 * s, 10 * s, dark)
    |> Canvas.fill(x + 1 * s, y + 6 * s, 14 * s, 8 * s, Render.rgb("#b5651d"))
    |> Canvas.fill(x + 2 * s, y + 7 * s, 6 * s, 6 * s, dark)
    |> Canvas.fill(x + 3 * s, y + 8 * s, 4 * s, 4 * s, Render.rgb("#555555"))
    |> Canvas.fill(x + 10 * s, y + 8 * s, 4 * s, 2 * s, Render.rgb("#f2e394"))
    |> Canvas.fill(x + 11 * s, y + 11 * s, 2 * s, 2 * s, dark)
  end

  # An arrow down to a tray (downloads, torrents).
  defp icon(c, x, y, :torrent, size) do
    s = div(size, 16)
    green = Render.rgb("#008000")
    dark = Render.rgb(@dark)

    c =
      c
      |> Canvas.fill(x + 6 * s, y, 4 * s, 7 * s, green)
      |> Canvas.fill(x, y + 12 * s, 16 * s, 4 * s, dark)
      |> Canvas.fill(x + 1 * s, y + 13 * s, 14 * s, 2 * s, Render.rgb("#888888"))

    Enum.reduce(0..3, c, fn i, c -> Canvas.fill(c, x + (2 + i) * s, y + (7 + i) * s, (12 - 2 * i) * s, s, green) end)
  end

  # A page with a big T and lines of text (the Typst editor).
  defp icon(c, x, y, :typst, size) do
    s = div(size, 16)
    teal = Render.rgb("#239dad")

    c
    |> Canvas.fill(x + 2 * s, y, 12 * s, 16 * s, Render.rgb(@dark))
    |> Canvas.fill(x + 3 * s, y + 1 * s, 10 * s, 14 * s, Render.rgb(@white))
    |> Canvas.fill(x + 5 * s, y + 3 * s, 6 * s, 2 * s, teal)
    |> Canvas.fill(x + 7 * s, y + 5 * s, 2 * s, 5 * s, teal)
    |> Canvas.fill(x + 5 * s, y + 11 * s, 6 * s, 1 * s, Render.rgb("#888888"))
    |> Canvas.fill(x + 5 * s, y + 13 * s, 4 * s, 1 * s, Render.rgb("#888888"))
  end

  # A padlock (the password manager).
  defp icon(c, x, y, :vault, size) do
    s = div(size, 16)
    dark = Render.rgb(@dark)

    c
    |> Canvas.fill(x + 4 * s, y, 8 * s, 2 * s, dark)
    |> Canvas.fill(x + 3 * s, y + 1 * s, 2 * s, 6 * s, dark)
    |> Canvas.fill(x + 11 * s, y + 1 * s, 2 * s, 6 * s, dark)
    |> Canvas.fill(x + 1 * s, y + 6 * s, 14 * s, 10 * s, dark)
    |> Canvas.fill(x + 2 * s, y + 7 * s, 12 * s, 8 * s, Render.rgb("#d4a017"))
    |> Canvas.fill(x + 7 * s, y + 9 * s, 2 * s, 4 * s, dark)
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

  # A drive: a grey box with a slot and a green light.
  defp icon(c, x, y, :drive, size) do
    s = div(size, 16)

    c
    |> Canvas.bevel(x, y + 4 * s, 16 * s, 9 * s, :raised)
    |> Canvas.fill(x + 2 * s, y + 7 * s, 9 * s, max(s, 1), Render.rgb(@dark))
    |> Canvas.fill(x + 12 * s, y + 9 * s, 2 * s, 2 * s, Render.rgb("#00c000"))
  end

  # A database: a stack of disks (a cylinder).
  defp icon(c, x, y, :database, size) do
    s = div(size, 16)
    body = Render.rgb("#336791")
    top = Render.rgb("#6f9bc4")
    rim = Render.rgb(@dark)

    c =
      c
      |> Canvas.fill(x + 2 * s, y + 2 * s, 12 * s, 12 * s, body)
      |> Canvas.fill(x + 3 * s, y + 1 * s, 10 * s, 1 * s, top)
      |> Canvas.fill(x + 2 * s, y + 2 * s, 12 * s, 2 * s, top)
      |> Canvas.fill(x + 3 * s, y + 14 * s, 10 * s, 1 * s, body)

    # The disks' edges, and the outline.
    Enum.reduce([4, 8, 12], c, fn dy, c -> Canvas.fill(c, x + 2 * s, y + dy * s, 12 * s, max(div(s, 2), 1), rim) end)
    |> Canvas.fill(x + 2 * s - 1, y + 2 * s, 1, 12 * s, rim)
    |> Canvas.fill(x + 14 * s, y + 2 * s, 1, 12 * s, rim)
    |> Canvas.fill(x + 3 * s, y + 15 * s, 10 * s, 1, rim)
    |> Canvas.fill(x + 3 * s, y + 1 * s - 1, 10 * s, 1, rim)
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
