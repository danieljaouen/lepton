defmodule Lepton.Photon.Screen do
  @moduledoc """
  Photon's screen: one desktop shown on one or more displays (each a
  `Lepton.Photon.Output`, a framebuffer). The first display is the
  primary one: `/dev/fb0`, where the console was.

    * `:extend` - the displays side by side, left to right in the order
      given, tops aligned. The desktop is as wide as all of them together
      and as tall as the primary.
    * `:mirror` - every display shows the primary's picture, scaled to fit
      and centred (black bars fill the rest).

  Photon composes in desktop coordinates; `write/2` hands each display its
  part of the rows (scaled, for a mirror of another size).

  A display is `%{out, rect: {x, y, w, h}, origin: {ox, oy}, scale: {num, den}}`:
  the part of the desktop it shows, where that lands on the display, and
  the scale (display pixels per desktop pixel, `num / den`).
  """

  alias Lepton.Photon.Output

  defstruct [:width, :height, mode: :extend, displays: []]

  @doc "A screen over `outputs` (opened `Output`s, the primary first)."
  def new([primary | _] = outputs, mode \\ :extend) when mode in [:extend, :mirror] do
    {w, h} = {primary.width, primary.height}

    displays =
      case mode do
        :extend ->
          {ds, _} =
            Enum.map_reduce(outputs, 0, fn o, x ->
              {%{out: o, rect: {x, 0, o.width, min(o.height, h)}, origin: {0, 0}, scale: {1, 1}}, x + o.width}
            end)

          ds

        :mirror ->
          for o <- outputs do
            # Scale to the tighter of the two fits; integer arithmetic throughout.
            scale = if o.width * h <= o.height * w, do: {o.width, w}, else: {o.height, h}
            {num, den} = scale
            origin = {div(o.width - div(w * num, den), 2), div(o.height - div(h * num, den), 2)}
            %{out: o, rect: {0, 0, w, h}, origin: origin, scale: if(num == den, do: {1, 1}, else: scale)}
          end
      end

    width = if mode == :extend, do: Enum.sum(Enum.map(outputs, & &1.width)), else: w
    %__MODULE__{width: width, height: h, mode: mode, displays: displays}
  end

  @doc "The outputs, primary first."
  def outputs(%__MODULE__{displays: ds}), do: Enum.map(ds, & &1.out)

  @doc "The same outputs in another mode."
  def relayout(screen, mode), do: new(outputs(screen), mode)

  @doc "The part of the desktop each display shows: `[{x, y, w, h}]` (one rectangle when mirrored)."
  def rects(%__MODULE__{mode: :mirror, width: w, height: h}), do: [{0, 0, w, h}]
  def rects(%__MODULE__{displays: ds}), do: Enum.map(ds, & &1.rect)

  @doc "The display rectangle containing `{x, y}` (else the primary's)."
  def rect_at(screen, {x, y}) do
    [first | _] = rects = rects(screen)
    Enum.find(rects, first, fn {rx, ry, rw, rh} -> x >= rx and x < rx + rw and y >= ry and y < ry + rh end)
  end

  @doc "Write desktop rows `[{x, y, pixels}]` to every display that shows them."
  def write(%__MODULE__{displays: ds}, rows) do
    for d <- ds do
      case Enum.flat_map(rows, &place(d, &1)) do
        [] -> :ok
        placed -> Output.write(d.out, placed)
      end
    end

    :ok
  end

  @doc "A desktop row as the display's rows: `[{x, y, pixels}]` in display coordinates."
  def place(%{rect: {lx, ly, lw, lh}, origin: {ox, oy}, scale: scale}, {x, y, px}) do
    n = div(byte_size(px), 4)
    a = max(x, lx)
    b = min(x + n, lx + lw)

    cond do
      y < ly or y >= ly + lh or a >= b ->
        []

      scale == {1, 1} ->
        [{a - lx + ox, y - ly + oy, binary_part(px, (a - x) * 4, (b - a) * 4)}]

      true ->
        # Nearest neighbour: display pixel i shows desktop pixel floor(i * den / num).
        {num, den} = scale
        seg = binary_part(px, (a - x) * 4, (b - a) * 4)
        x0 = cdiv((a - lx) * num, den)
        x1 = cdiv((b - lx) * num, den)
        y0 = cdiv((y - ly) * num, den)
        y1 = cdiv((y - ly + 1) * num, den)

        if x1 > x0 and y1 > y0 do
          skip = a - lx
          row = for i <- x0..(x1 - 1), into: <<>>, do: binary_part(seg, (div(i * den, num) - skip) * 4, 4)
          for r <- y0..(y1 - 1), do: {x0 + ox, r + oy, row}
        else
          []
        end
    end
  end

  defp cdiv(a, b), do: div(a + b - 1, b)

  @doc """
  Read a rectangle of the desktop back (for screenshots), from the displays
  that show it unscaled; what no display shows is black.
  """
  def read(%__MODULE__{displays: ds}, x, y, w, h) do
    black = :binary.copy(<<0, 0, 0, 255>>, w)
    rows = List.duplicate(black, h)

    ds
    |> Enum.filter(&(&1.scale == {1, 1}))
    |> Enum.reverse()
    |> Enum.reduce(rows, fn %{rect: {lx, ly, lw, lh}, origin: {ox, oy}, out: out}, rows ->
      a = max(x, lx)
      b = min(x + w, lx + lw)
      c = max(y, ly)
      d = min(y + h, ly + lh)

      if a < b and c < d do
        got = Output.read(out, a - lx + ox, c - ly + oy, b - a, d - c)
        len = (b - a) * 4
        off = (a - x) * 4

        Enum.with_index(rows, fn row, i ->
          r = y + i

          if r >= c and r < d do
            <<pre::binary-size(^off), _::binary-size(^len), post::binary>> = row
            <<pre::binary, binary_part(got, (r - c) * len, len)::binary, post::binary>>
          else
            row
          end
        end)
      else
        rows
      end
    end)
    |> IO.iodata_to_binary()
  end

  @doc "Fill every display with black (before showing the desktop on it)."
  def clear(%__MODULE__{} = screen), do: Enum.each(outputs(screen), &Output.clear/1)
end
