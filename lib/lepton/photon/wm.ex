defmodule Lepton.Photon.WM do
  @moduledoc """
  Window managers for Photon. The compositor keeps the protocol, the
  windows and their stacking; a window manager decides how they look and
  what the desktop around them is:

    * decorations: `frame_size/2`, `content_offset/0`, `frame_part/4`
      (what a point of a frame is: `:title`, `:close`, `:maximize`,
      `:minimize`, `:corner`, `:border` or `:content`), `decorations/4`
      (the frame's rows above the content) and `frame_layer/7`
    * the desktop: `init/3` (the desktop's size, and the primary
      display's when the desktop extends across several), `background/1`
      and `work_area/1` (where windows go and maximize to, on each display)
    * its own surfaces: `layers/2` returns `{below_windows, above_windows}`
      (desktop icons; a taskbar and menus), redrawn whenever `signature/2`
      changes
    * input: `click/5` and `motion/3` see the pointer before the windows
      do, `desktop_click/4` gets clicks that reach the desktop, and
      `menu/2` answers the menu key (Ctrl+Esc)

  Window managers return actions for Photon to carry out: `{:focus, key}`
  (also restores a minimized window), `{:minimize, key}`,
  `{:spawn, opts}` (open a terminal; `opts[:command]`) and `:quit`.

  `info` is the toplevel windows in the order they opened:
  `%{key, title, focused, minimized}`.
  """

  @type layer :: %{x: integer, y: integer, w: integer, h: integer, row: (integer -> binary)}

  @callback init(width :: integer, height :: integer, primary :: {integer, integer}) :: term
  @callback frame_size(integer, integer) :: {integer, integer}
  @callback content_offset() :: {integer, integer}
  @callback frame_part(integer, integer, integer, integer) :: atom
  @callback decorations(String.t(), integer, boolean, boolean) :: [binary]
  @callback frame_layer(integer, integer, integer, integer, [binary], boolean, (integer -> binary)) :: layer
  @callback background(term) :: (integer -> binary)
  @callback work_area(term) :: {integer, integer, integer, integer}
  @callback layers(term, list) :: {[layer], [layer]}
  @callback signature(term, list) :: term
  @callback click(term, list, {number, number}, integer, boolean) :: {:handled | :pass, term, list}
  @callback desktop_click(term, list, {number, number}, boolean) :: {term, list}
  @callback motion(term, list, {number, number}) :: term
  @callback menu(term, list) :: term

  @doc "The window manager called `name` (`\"photon\"`, `\"classic\"`)."
  def get("classic"), do: Lepton.Photon.WM.Classic
  def get(_), do: Lepton.Photon.WM.Default
end

defmodule Lepton.Photon.WM.Default do
  @moduledoc "Photon's own look: thin borders, a title bar with a close button, Monokai colours."

  @behaviour Lepton.Photon.WM

  alias Lepton.Photon.Render

  @help "Photon   Alt+Return: terminal   Alt+Tab: next window   Alt+F4: close   Ctrl+Alt+Backspace: quit"

  @impl true
  def init(w, h, _primary), do: %{w: w, h: h}

  @impl true
  def frame_size(w, h), do: Render.frame_size(w, h)

  @impl true
  def content_offset, do: Render.content_origin(0, 0)

  @impl true
  def frame_part(fw, fh, px, py), do: Render.frame_part(fw, fh, px, py)

  @impl true
  def decorations(title, fw, focused?, _maximized?), do: Render.title_rows(title, fw, focused?)

  @impl true
  def frame_layer(x, y, cw, ch, rows, focused?, content_row), do: Render.frame_layer(x, y, cw, ch, rows, focused?, content_row)

  @impl true
  def background(s), do: Render.background(s.w, s.h, @help)

  @impl true
  def work_area(s), do: {0, 0, s.w, s.h}

  @impl true
  def layers(_s, _info), do: {[], []}

  @impl true
  def signature(_s, _info), do: nil

  @impl true
  def click(s, _info, _pos, _button, _double?), do: {:pass, s, []}

  @impl true
  def desktop_click(s, _info, _pos, _double?), do: {s, []}

  @impl true
  def motion(s, _info, _pos), do: s

  @impl true
  def menu(s, _info), do: s
end
