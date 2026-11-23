defmodule Lepton.Photon.Shot do
  @moduledoc """
  Screenshots on the desktop: what Photon draws while you pick a region
  (an outline), the notice that says where a screenshot went, and the
  names screenshots are saved under.

  The keys (Photon): Print, or Super+Shift+3, the whole desktop;
  Alt+Print, or Super+Shift+5, the focused window; Shift+Print, or
  Super+Shift+4, a region you drag (a click takes the window under the
  pointer; Esc cancels). The `screenshot` command does the same from a
  shell.
  """

  alias Lepton.Photon.{Canvas, Render}

  @outline Render.rgb("#3d8ef0")
  @notice_bg "#202830"
  @notice_fg "#ffffff"
  @notice_ms 4000

  @doc "How long a notice stays up (ms)."
  def notice_ms, do: @notice_ms

  @doc "The file name for a screenshot taken at `time` (local): `Screenshot-2026-11-23-153005.png`."
  def filename(t) do
    pad = &String.pad_leading(Integer.to_string(&1), 2, "0")
    "Screenshot-#{t.year}-#{pad.(t.month)}-#{pad.(t.day)}-#{pad.(t.hour)}#{pad.(t.minute)}#{pad.(t.second)}.png"
  end

  @doc "A path in `dir` for a screenshot now, not one that exists already (`-2`, `-3`, ...)."
  def new_path(dir, now \\ Lepton.Time.local()) do
    base = Path.rootname(filename(now))
    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn 1 -> base <> ".png"; n -> "#{base}-#{n}.png" end)
    |> Enum.find_value(&(not File.exists?(Path.join(dir, &1)) && Path.join(dir, &1)))
  end

  @doc "The rectangle between two points, both included: `{x, y, w, h}`."
  def rect({x1, y1}, {x2, y2}) do
    {x1, y1, x2, y2} = {trunc(x1), trunc(y1), trunc(x2), trunc(y2)}
    {min(x1, x2), min(y1, y2), abs(x2 - x1) + 1, abs(y2 - y1) + 1}
  end

  @doc "`rect` cut to the desktop (`w` x `h`); nil when nothing is left."
  def clip({x, y, rw, rh}, w, h) do
    a = max(x, 0)
    b = max(y, 0)
    c = min(x + rw, w)
    d = min(y + rh, h)
    if c > a and d > b, do: {a, b, c - a, d - b}
  end

  @doc "A region's outline: four thin layers (the inside stays as it is)."
  def outline({x, y, w, h}) do
    line = fn lx, ly, lw, lh -> %{x: lx, y: ly, w: lw, h: lh, row: fn _ -> :binary.copy(@outline, lw) end} end
    [line.(x - 2, y - 2, w + 4, 2), line.(x - 2, y + h, w + 4, 2), line.(x - 2, y, 2, h), line.(x + w, y, 2, h)]
  end

  @doc "A notice at the top right of a desktop `width` wide: `text`, in a dark box."
  def notice(text, width) do
    tw = Canvas.text_width(text)
    w = min(tw + 24, width - 16)
    h = 28
    bg = Render.rgb(@notice_bg)
    c = Canvas.new(w, h, bg) |> Canvas.text(12, 6, text, Render.rgb(@notice_fg), bg, max_w: w - 24)
    rows = Canvas.rows(c) |> List.to_tuple()
    %{x: width - w - 8, y: 8, w: w, h: h, row: &elem(rows, &1)}
  end
end
