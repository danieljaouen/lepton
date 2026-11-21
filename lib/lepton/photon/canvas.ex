defmodule Lepton.Photon.Canvas do
  @moduledoc """
  A small raster canvas for window-manager chrome (taskbars, menus,
  buttons): rows of XRGB pixels with fills, 3D bevels, text and pixel art.
  """

  alias Lepton.Photon.Render
  alias Lepton.Wayland.Font

  defstruct [:w, :h, :rows]

  def new(w, h, color), do: %__MODULE__{w: w, h: h, rows: List.to_tuple(List.duplicate(:binary.copy(color, w), h))}

  def rows(%__MODULE__{rows: rows}), do: Tuple.to_list(rows)

  @doc "Put `pixels` (a binary) into row `y` at column `x`, clipped."
  def put(%__MODULE__{w: w, h: h} = c, x, y, pixels) when y >= 0 and y < h do
    {pixels, x} = if x < 0, do: {binary_part(pixels, min(-x * 4, byte_size(pixels)), max(byte_size(pixels) + x * 4, 0)), 0}, else: {pixels, x}
    len = min(byte_size(pixels), max((w - x) * 4, 0))

    if len > 0 do
      row = elem(c.rows, y)
      off = x * 4
      <<pre::binary-size(^off), _::binary-size(^len), post::binary>> = row
      %{c | rows: put_elem(c.rows, y, <<pre::binary, binary_part(pixels, 0, len)::binary, post::binary>>)}
    else
      c
    end
  end

  def put(c, _x, _y, _pixels), do: c

  def fill(c, x, y, w, h, color) when w > 0 and h > 0 do
    line = :binary.copy(color, w)
    Enum.reduce(y..(y + h - 1), c, &put(&2, x, &1, line))
  end

  def fill(c, _x, _y, _w, _h, _color), do: c

  @doc "Draw rows of pixels with their top-left at `{x, y}`."
  def blit(c, x, y, rows), do: rows |> Enum.with_index() |> Enum.reduce(c, fn {row, i}, c -> put(c, x, y + i, row) end)

  @face "#c0c0c0"
  @light "#dfdfdf"
  @white "#ffffff"
  @shadow "#808080"
  @dark "#000000"

  @doc """
  A 3D box: `:raised` (buttons, windows), `:sunken` (fields, pressed
  buttons) or `:pressed` (a pushed button: one dark line).
  """
  def bevel(c, x, y, w, h, style, face \\ @face) do
    {tl1, tl2, br2, br1} =
      case style do
        :raised -> {@white, @light, @shadow, @dark}
        :sunken -> {@shadow, @dark, @light, @white}
        :pressed -> {@dark, @shadow, @face, @white}
        :thin_sunken -> {@shadow, nil, nil, @white}
        :thin_raised -> {@white, nil, nil, @shadow}
      end

    c = fill(c, x, y, w, h, Render.rgb(face))
    c = line(c, x, y, w, h, tl1, br1, 0)
    if tl2, do: line(c, x, y, w, h, tl2, br2, 1), else: c
  end

  # One ring of a bevel, `i` pixels in: top and left in `tl`, bottom and right in `br`.
  defp line(c, x, y, w, h, tl, br, i) do
    tl = Render.rgb(tl)
    br = Render.rgb(br)

    c
    |> fill(x + i, y + i, w - 2 * i - 1, 1, tl)
    |> fill(x + i, y + i, 1, h - 2 * i - 1, tl)
    |> fill(x + i, y + h - 1 - i, w - 2 * i, 1, br)
    |> fill(x + w - 1 - i, y + i, 1, h - 2 * i, br)
  end

  @doc "Text in the 8x16 font on a known background colour; clipped to `max_w` pixels."
  def text(c, x, y, text, fg, bg, opts \\ []) do
    max_w = opts[:max_w] || c.w - x
    bold? = opts[:bold] == true
    text
    |> Font.fit(max(max_w, 0))
    |> Enum.reduce({c, x}, fn cp, {c, x} ->
      {blit(c, x, y, Font.rows(cp, fg, bg, bold?)), x + Font.char_width(cp)}
    end)
    |> elem(0)
  end

  def text_width(text), do: Font.text_width(text)

  @doc """
  Pixel art: rows of characters, each looked up in `palette` (a colour
  hex string); characters not in the palette are left as they are.
  """
  def art(c, x, y, art, palette) do
    palette = Map.new(palette, fn {k, v} -> {k, Render.rgb(v)} end)

    art
    |> Enum.with_index()
    |> Enum.reduce(c, fn {line, dy}, c ->
      line
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.chunk_by(fn {ch, _} -> Map.has_key?(palette, ch) end)
      |> Enum.reduce(c, fn [{ch, _} | _] = run, c ->
        if Map.has_key?(palette, ch) do
          {_, dx} = hd(run)
          put(c, x + dx, y + dy, IO.iodata_to_binary(Enum.map(run, fn {ch, _} -> palette[ch] end)))
        else
          c
        end
      end)
    end)
  end

  @doc "Text turned a quarter turn anticlockwise (reads bottom to top), as rows."
  def vertical_text(text, fg, bg) do
    w = Font.text_width(text)
    rows = Font.text_rows(text, fg, bg, w) |> Enum.map(&for(<<p::binary-size(4) <- &1>>, do: p)) |> Enum.map(&List.to_tuple/1)
    h = length(rows)

    for x <- (w - 1)..0//-1 do
      IO.iodata_to_binary(for r <- 0..(h - 1), do: elem(Enum.at(rows, r), x))
    end
  end
end
