defmodule Lepton.Photon.Render do
  @moduledoc """
  Composition: the background, then the windows bottom to top, then the
  pointer, for the damaged rectangles of the screen only.

  A layer is `%{x, y, w, h, row: fun}` where `row.(r)` returns row `r` of
  the layer (`w` XRGB pixels). Each screen row of a damaged rectangle
  starts as the background and has each overlapping layer's pixels
  spliced in.
  """

  alias Lepton.Wayland.Font

  @doc "An XRGB8888 pixel."
  def px(r, g, b), do: <<b, g, r, 255>>

  def rgb(hex) do
    <<r, g, b>> = Base.decode16!(String.trim_leading(hex, "#"), case: :mixed)
    px(r, g, b)
  end

  @doc "Compose `rect` = `{x, y, w, h}`: `[{x, y, pixels}]` rows for the output."
  def compose({x0, y0, w, h}, background, layers, cursor) do
    for y <- y0..(y0 + h - 1)//1 do
      row = binary_part(background.(y), x0 * 4, w * 4)

      row =
        Enum.reduce(layers, row, fn l, row ->
          if y >= l.y and y < l.y + l.h do
            a = max(x0, l.x)
            b = min(x0 + w, l.x + l.w)
            if a < b, do: splice(row, (a - x0) * 4, binary_part(l.row.(y - l.y), (a - l.x) * 4, (b - a) * 4)), else: row
          else
            row
          end
        end)

      {x0, y, overlay_cursor(row, x0, w, y, cursor)}
    end
  end

  defp splice(row, off, seg) do
    len = byte_size(seg)
    <<pre::binary-size(^off), _::binary-size(^len), post::binary>> = row
    <<pre::binary, seg::binary, post::binary>>
  end

  # -- the pointer ------------------------------------------------------------------------

  @arrow """
  X
  XX
  X.X
  X..X
  X...X
  X....X
  X.....X
  X......X
  X.......X
  X........X
  X.........X
  X......XXXXX
  X...X..X
  X..XX..X
  X.X  X..X
  XX   X..X
  X     X..X
        X..X
         XX
  """

  @cursor_rows @arrow
               |> String.split("\n", trim: true)
               |> Enum.map(fn line ->
                 for {c, i} <- Enum.with_index(String.graphemes(line)), c != " ", do: {i, if(c == "X", do: :outline, else: :fill)}
               end)

  def cursor_size, do: {12, length(@cursor_rows)}

  defp overlay_cursor(row, _x0, _w, _y, nil), do: row

  defp overlay_cursor(row, x0, w, y, {cx, cy}) do
    case Enum.at(@cursor_rows, y - cy) do
      pixels when y >= cy and pixels != nil ->
        Enum.reduce(pixels, row, fn {i, kind}, row ->
          x = cx + i
          if x >= x0 and x < x0 + w, do: splice(row, (x - x0) * 4, if(kind == :outline, do: px(0, 0, 0), else: px(255, 255, 255))), else: row
        end)

      _ ->
        row
    end
  end

  # -- window decorations (Monokai, like the rest of Lepton) -------------------------------------------------------------------

  @title_h 24
  @border 1
  @close 16

  def title_height, do: @title_h
  def border, do: @border

  @theme %{
    true => %{title: "#49483e", text: "#f8f8f2", border: "#66d9ef", close: "#f92672"},
    false => %{title: "#2d2e27", text: "#90908a", border: "#3e3d32", close: "#49483e"}
  }

  @doc "Frame size for content of `w` x `h`."
  def frame_size(w, h), do: {w + 2 * @border, h + @title_h + 2 * @border}

  @doc "Where the content of a frame at `{x, y}` starts."
  def content_origin(x, y), do: {x + @border, y + @border + @title_h}

  @doc "What part of a frame `{fx, fy}` is at frame-relative point `{px, py}` (frame width `fw`)."
  def frame_part(fw, fh, px, py) do
    cond do
      px >= fw - 12 and py >= fh - 12 -> :corner
      py < @border + @title_h and py >= @border + 4 and py < @border + 4 + @close and px >= fw - @border - 4 - @close and px < fw - @border - 4 -> :close
      py < @border + @title_h -> :title
      px < @border or px >= fw - @border or py >= fh - @border -> :border
      true -> :content
    end
  end

  @doc "The title bar rows (frame width) of a window."
  def title_rows(title, fw, focused?) do
    t = Map.new(@theme[focused?], fn {k, v} -> {k, rgb(v)} end)
    inner = fw - 2 * @border
    text_w = max(inner - 8 - @close - 8, 0)
    text = Font.text_rows(title || "", t.text, t.title, text_w)
    pad4 = :binary.copy(t.close, 4)
    close = Font.rows(0xD7, t.text, t.close) |> Enum.map(&(pad4 <> &1 <> pad4))
    blank = :binary.copy(t.title, inner)
    edge = t.border

    rows =
      for r <- 0..(@title_h - 1) do
        if r >= 4 and r < 20 do
          [:binary.copy(t.title, 8), Enum.at(text, r - 4), :binary.copy(t.title, 4), Enum.at(close, r - 4), :binary.copy(t.title, 4)]
          |> IO.iodata_to_binary()
          |> fit(inner, t.title)
        else
          blank
        end
      end

    top = :binary.copy(edge, fw)
    [top | Enum.map(rows, &IO.iodata_to_binary([edge, &1, edge]))]
  end

  defp fit(row, w, fill) do
    cond do
      byte_size(row) >= w * 4 -> binary_part(row, byte_size(row) - w * 4, w * 4)
      true -> :binary.copy(fill, w - div(byte_size(row), 4)) <> row
    end
  end

  @doc """
  A decorated window's layer: frame at `{x, y}`, content `cw` x `ch`
  taken from `content_row.(r)`.
  """
  def frame_layer(x, y, cw, ch, title_rows, focused?, content_row) do
    {fw, fh} = frame_size(cw, ch)
    edge = rgb(@theme[focused?].border)
    bottom = :binary.copy(edge, fw)
    top = @border + @title_h

    row = fn
      r when r < top -> Enum.at(title_rows, r)
      r when r >= fh - @border -> bottom
      r -> <<edge::binary, content_row.(r - top)::binary, edge::binary>>
    end

    %{x: x, y: y, w: fw, h: fh, row: row}
  end

  # -- background ---------------------------------------------------------------------------

  @doc """
  The background: a solid colour with a line of help at the bottom left.
  Returns a function from row to pixels.
  """
  def background(w, h, help) do
    bg = rgb("#1e1f1c")
    plain = :binary.copy(bg, w)
    text = Font.text_rows(help, rgb("#75715e"), bg, max(w - 32, 0)) |> Enum.map(&(:binary.copy(bg, 16) <> &1 <> :binary.copy(bg, 16)))
    top = h - 16 - 12
    rows = Map.new(Enum.with_index(text), fn {row, i} -> {top + i, row} end)
    fn y -> Map.get(rows, y, plain) end
  end
end
