defmodule Lepton.ListMouse do
  @moduledoc """
  Clicks and the wheel in a full-screen list (the Media Player's files,
  the SNES games, Radio's stations): a click selects a line, a double
  click opens it, the wheel moves up and down. `on/0` asks the terminal
  for mouse reports (presses and the wheel, in SGR form), `off/0` stops.
  """

  @double_ms 500

  def on, do: "\e[?1000h\e[?1006h"
  def off, do: "\e[?1000l\e[?1006l"

  @doc """
  What a key does to a list whose lines start at screen row `first`
  (from 0), `height` of them shown from item `top`, `n` items. `last` is
  the previous click (`{item, time}` or nil), `now` milliseconds:

    * `{:select, i, last}`: a click on item `i` (keep `last` for the next);
    * `{:open, i}`: a double click on it;
    * `{:move, delta}`: the wheel (3 items a notch);
    * `:none`: anything else.
  """
  def action(key, view, last, now \\ System.monotonic_time(:millisecond))

  def action({:mouse, :press, :left, _x, row, _}, %{first: first, height: h, top: top, n: n}, last, now) do
    i = top + row - first

    cond do
      row < first or row >= first + h or i >= n -> :none
      match?({^i, t} when now - t <= @double_ms, last) -> {:open, i}
      true -> {:select, i, {i, now}}
    end
  end

  def action({:mouse, :press, :wheel_up, _, _, _}, _view, _last, _now), do: {:move, -3}
  def action({:mouse, :press, :wheel_down, _, _, _}, _view, _last, _now), do: {:move, 3}
  def action(_key, _view, _last, _now), do: :none

  @doc "The first item shown, `height` lines from `top`, so that `sel` is in view."
  def top(sel, top, height) do
    cond do
      sel < top -> sel
      sel >= top + height -> sel - height + 1
      true -> top
    end
    |> max(0)
  end
end
