defmodule Lepton.Editor do
  @moduledoc """
  `le` - the Lepton editor: an evil-mode editor that behaves like the
  user's Spacemacs.

  Keymaps are Spacemacs defaults overlaid with the user's own bindings
  (`~/.spacemacs.d/keybindings.el`), and editing variables come from their
  config (`~/.spacemacs.d/editing.el`): relative line numbers, fill-column
  indicator at column 101, `jk` evil-escape with a 0.4s delay,
  case-sensitive search, delete-trailing-whitespace on save, Monokai.

  Spacemacs' `tmux` layer is honoured: `C-h`/`C-j`/`C-k`/`C-l` move between
  editor windows and, at the edge, on to neighbouring multiplexer panes.
  """

  alias Lepton.{Keys, TTY}
  alias Lepton.Editor.{Buffer, Fold, Keymap, Motion, Render, Magit}

  defstruct buffers: %{},
            order: [],
            windows: %{},
            layout: nil,
            active: nil,
            last_window: nil,
            mode: :normal,
            pending: [],
            count: nil,
            operator: nil,
            op_count: nil,
            register: {:char, ""},
            # named registers ("a ... "z, "0 the last yank), and the one " chose for the next yank, delete or paste
            registers: %{},
            use_register: nil,
            message: nil,
            message_error: false,
            minibuffer: nil,
            search: nil,
            last_find: nil,
            visual_start: nil,
            # visual block: `$` (every line to its end); an I, A or c being typed, for the block's other lines
            block_eol: false,
            block_insert: nil,
            last_visual: nil,
            km: nil,
            vars: %{},
            emacs: nil,
            size: {24, 80},
            tty: nil,
            ctx: nil,
            quit: false,
            frame: [],
            recording: nil,
            last_change: [],
            replaying: false,
            jk_pending: nil,
            completion: nil,
            maximized: nil,
            messages: [],
            prev_buffer: nil,
            insert_snapshot: false,
            # keyboard macros: `q` + register records, `@` + register plays
            # (`@@` the last one played); {register, keys} while recording
            macros: %{},
            # where they're kept across sessions (Lepton.Editor.Macros)
            macros_file: nil,
            macro_rec: nil,
            macro_pending: nil,
            last_macro: nil,
            macro_depth: 0,
            # a motion that couldn't move (j on the last line): ends the macro playing
            motion_failed: false,
            # r and C-q: the next key is their character ({:replace_char, count} or :quoted_insert)
            awaiting: nil,
            # uppercase marks, which name a file too: %{"A" => buffer id}
            global_marks: %{},
            # a project replace (SPC p R) asking about each match: see query_key/2
            query: nil

  defmodule Win do
    @moduledoc false
    defstruct id: nil, buf: nil, cursor: {0, 0}, top: 0, left: 0, want_col: 0, jumps: []
  end

  @default_vars %{
    # Typst files: compile to a PDF on each save (SPC m w toggles)
    "typst-compile-on-save" => true,
    "fill-column" => 79,
    "display-fill-column-indicator-column" => 101,
    "display-line-numbers-type" => "relative",
    "evil-escape-key-sequence" => "jk",
    "evil-escape-delay" => 0.4,
    "case-fold-search" => false,
    "line-numbers" => true,
    "fill-column-indicator" => true,
    "truncate-lines" => true,
    "show-whitespace" => false,
    "delete-trailing-whitespace-on-save" => true,
    "theme" => "monokai"
  }

  # -- entry point --------------------------------------------------------------------

  @doc "Run the editor on `files` using the terminal in `ctx`. Returns exit status."
  def run(files, ctx, opts \\ []) do
    st = init(files, ctx, opts)
    TTY.set_mode(ctx.tty, :raw)
    # The mouse reports presses, drags and releases (1002), in SGR form (1006).
    # (and bracketed paste, 2004: a paste comes as one piece of text)
    TTY.write(ctx.tty, "\e[?1049h\e[?25l\e[?1002h\e[?1006h\e[?2004h")

    try do
      st |> redraw(true) |> loop()
      0
    after
      TTY.write(ctx.tty, "\e[?2004l\e[?1002l\e[?1006l\e[0m\e[?25h\e[?1049l")
      TTY.set_mode(ctx.tty, :cooked)
    end
  end

  def init(files, ctx, opts \\ []) do
    emacs = Lepton.Dotfiles.emacs(Lepton.Ctx.home(ctx))
    km = Keymap.build(emacs)
    vars = Map.merge(@default_vars, emacs.vars)
    vars = if emacs.themes != [], do: Map.put(vars, "theme", hd(emacs.themes)), else: vars
    vars = Map.put(vars, "line-numbers", vars["display-line-numbers-type"] not in [nil, false])

    st = %__MODULE__{km: km, vars: vars, emacs: emacs, ctx: ctx, tty: ctx.tty, size: if(ctx.tty, do: TTY.size(ctx.tty), else: {24, 80})}
    # The macros recorded in earlier sessions.
    file = Lepton.Editor.Macros.path(ctx)
    st = %{st | macros_file: file, macros: Lepton.Editor.Macros.load(file)}

    files = if files == [], do: [nil], else: files

    st =
      Enum.reduce(files, st, fn
        nil, st -> add_buffer(st, Buffer.new("*scratch*", ";; This buffer is for text that is not saved.\n", kind: :scratch, mode: "Text"))
        f, st -> open_path(st, Lepton.Ctx.path(ctx, f))
      end)

    st = if opts[:typst_starter], do: typst_starter(st), else: st
    first = hd(st.order)
    win = %Win{id: 1, buf: first}
    st = %{st | windows: %{1 => win}, layout: {:leaf, 1}, active: 1}
    show_buffer(st, first)
  end

  defp loop(%{quit: true} = st), do: st

  defp loop(st) do
    st = check_resize(st)

    key =
      cond do
        st.jk_pending -> TTY.read_key(st.tty, round((st.vars["evil-escape-delay"] || 0.4) * 1000))
        st.pending != [] -> TTY.read_key(st.tty, 500)
        true -> TTY.read_key(st.tty)
      end

    st =
      case key do
        :timeout -> timeout(st)
        {:cpr, _, _} -> st
        # The terminal was resized (see Lepton.TTY): adopt the size now.
        {:resize, _, _} -> check_resize(st)
        key -> handle_key(st, key)
      end

    st |> redraw(false) |> loop()
  end

  defp check_resize(st) do
    size = TTY.size(st.tty)
    if size != st.size, do: %{st | size: size, frame: []}, else: st
  rescue
    _ -> st
  catch
    :exit, _ -> %{st | quit: true}
  end

  # A pause after a prefix shows which-key; after `j` in insert mode it
  # commits the `j` (evil-escape gave up).
  defp timeout(%{jk_pending: true} = st), do: %{st | jk_pending: nil}
  defp timeout(st), do: %{st | message: {:which_key, st.pending}}

  @doc "Feed a key (also used by tests to drive the editor headlessly)."
  def handle_key(st, {:mouse, _, _, _, _, _} = m), do: mouse(st, m)
  def handle_key(st, {:paste, text}), do: bracketed_paste(st, text)

  def handle_key(st, key) do
    st = %{st | message: if(match?({:which_key, _}, st.message), do: nil, else: st.message)}
    st = if st.recording, do: %{st | recording: st.recording ++ [key]}, else: st
    # A macro being recorded takes every key typed (not those a macro plays).
    st = if st.macro_rec && st.macro_depth == 0, do: %{st | macro_rec: {elem(st.macro_rec, 0), [key | elem(st.macro_rec, 1)]}}, else: st

    cond do
      st.query && st.minibuffer == nil -> query_key(st, key)
      st.awaiting -> awaited(st, key)
      st.macro_pending -> macro_key(st, key)
      st.minibuffer -> minibuffer_key(st, key)
      st.mode in [:insert, :replace] -> insert_key(st, key)
      st.mode in [:visual, :visual_line, :visual_block] -> visual_key(st, key)
      buf(st).kind in [:magit, :dired, :help, :list, :log] -> special_key(st, key)
      true -> normal_key(st, key)
    end
  end

  # -- the mouse ---------------------------------------------------------------------------

  # A click puts the cursor where it points (in that window, which it
  # selects; on a mode line, just the window); a drag from there selects
  # text, as `v` does; the wheel scrolls the window under the pointer by
  # three lines. Not while the minibuffer or a popup takes the keys.
  @wheel_lines 3

  defp mouse(%{minibuffer: mb} = st, _) when mb != nil, do: st
  defp mouse(%{macro_pending: p} = st, _) when p not in [nil, false], do: st

  defp mouse(st, {:mouse, action, button, x, y, _mods}) do
    case {action, button, window_at(st, x, y)} do
      {_, _, nil} -> st
      {:press, :left, {id, :mode_line}} -> if id == st.active, do: st, else: select_window(st, id)
      {:press, :left, {id, pos}} -> st |> then(&if(&1.mode in [:visual, :visual_line, :visual_block], do: leave_visual(&1), else: &1)) |> focus(id) |> set_cursor(pos)
      {:drag, :left, {id, pos}} when id == st.active and st.mode not in [:insert, :replace] ->
        st = if st.mode in [:visual, :visual_line, :visual_block], do: st, else: do_action(st, :visual, 1)
        set_cursor(st, pos)
      {:press, wheel, {id, _}} when wheel in [:wheel_up, :wheel_down] ->
        active = st.active
        action = if wheel == :wheel_down, do: :scroll_line_down, else: :scroll_line_up
        st = %{st | active: id}
        st = Enum.reduce(1..@wheel_lines, st, fn _, st -> do_action(st, action, 1) end)
        %{st | active: active}
      _ -> st
    end
  end

  defp focus(st, id), do: if(id == st.active, do: st, else: %{st | active: id, last_window: st.active})

  # The window under screen cell (x, y), and the buffer position there
  # ({line, column}), or :mode_line.
  defp window_at(st, x, y) do
    Enum.find_value(rects(st), fn {id, {r, c, h, w}} ->
      if y >= r and y < r + h and x >= c and x < c + w do
        if y == r + h - 1, do: {id, :mode_line}, else: {id, position_at(st, id, y - r, x - c)}
      end
    end)
  end

  defp position_at(st, id, row, col) do
    win = st.windows[id]
    b = st.buffers[win.buf]
    text_h = view_height(st, id)

    line =
      if MapSet.size(b.folds) == 0,
        do: win.top + row,
        else: Enum.at(Fold.visible_lines(b, win.top, text_h), row) || Buffer.line_count(b)

    line = min(line, Buffer.line_count(b) - 1)
    {line, column_at(Buffer.line(b, line), max(col - Lepton.Editor.Render.gutter(st, b), 0) + win.left)}
  end

  # The character at display column `dc` of `line` (tabs to 8, wide characters two columns).
  def column_at(line, dc) do
    line
    |> String.graphemes()
    |> Enum.reduce_while({0, 0}, fn g, {i, col} ->
      w = if g == "\t", do: 8 - rem(col, 8), else: Lepton.Width.grapheme(g)
      if dc < col + w, do: {:halt, {i, col}}, else: {:cont, {i + 1, col + w}}
    end)
    |> elem(0)
  end

  # -- pasting from the terminal --------------------------------------------------------------

  # A paste from the terminal (Ctrl+Shift+V in a terminal window, Cmd-V over
  # SSH): the text as it is, newlines included, without auto-indent. In
  # insert mode at the cursor; in normal mode before it (staying normal);
  # over a visual selection, in its place; in a prompt, on its one line.
  # One undo takes it back.
  defp bracketed_paste(st, text) do
    text = text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

    cond do
      st.minibuffer ->
        text |> String.replace("\n", " ") |> String.graphemes() |> Enum.reduce(st, &minibuffer_key(&2, if(&1 == " ", do: "SPC", else: &1)))

      buf(st).read_only or buf(st).kind not in [:file, :scratch, :commit] ->
        msg(st, "Buffer is read-only", true)

      # (where the selection began: the cursor may have stepped back from the line's end)
      st.mode in [:visual, :visual_line, :visual_block] ->
        {{fl, fc}, _, _} = region(st)
        st = visual_action(st, :visual_delete, nil)
        l = min(fl, Buffer.line_count(buf(st)) - 1)
        paste_text_at(st, {l, min(fc, Buffer.line_length(buf(st), l))}, text)

      st.mode in [:insert, :replace] ->
        {b, pos} = Buffer.insert(buf(st), cursor(st), text)
        st |> put_buf(b) |> set_cursor(pos)

      true ->
        paste_text_at(snapshot(st), cursor(st), text)
    end
  end

  defp paste_text_at(st, pos, text) do
    {b, {el, ec}} = Buffer.insert(buf(st), pos, text)
    st |> put_buf(b) |> set_cursor({el, max(ec - 1, 0)})
  end

  # -- buffers & windows ------------------------------------------------------------------

  def buf(st), do: st.buffers[win(st).buf]
  def win(st), do: st.windows[st.active]
  defp put_buf(st, b) do
    # Folds follow their headings through edits (and undo).
    b =
      case st.buffers[b.id] do
        %{lines: old} when old != b.lines ->
          %{b | folds: Fold.remap(b.folds, old, b.lines), revealed: Fold.remap_revealed(b.revealed, b.folds, old, b.lines), marks: Fold.remap_marks(b.marks, old, b.lines)}
        _ -> b
      end

    %{st | buffers: Map.put(st.buffers, b.id, b)}
  end
  defp put_win(st, w), do: %{st | windows: Map.put(st.windows, w.id, w)}
  defp cursor(st), do: win(st).cursor

  defp set_cursor(st, {l, c}, opts \\ []) do
    b = buf(st)
    l = l |> max(0) |> min(Buffer.line_count(b) - 1)

    # A line inside a folded subtree: a search opens the fold, anything
    # else lands on the heading that hides it.
    {st, b, l} =
      cond do
        MapSet.size(b.folds) == 0 -> {st, b, l}
        opts[:reveal] -> b = Fold.reveal(b, l); {put_buf(st, b), b, l}
        true -> {st, b, Fold.shown(Fold.hidden(b), l)}
      end

    len = Buffer.line_length(b, l)
    max_c = if st.mode in [:insert, :replace] || opts[:eol], do: len, else: max(len - 1, 0)
    c = c |> max(0) |> min(max_c)
    w = win(st)
    w = %{w | cursor: {l, c}, want_col: if(opts[:keep_want], do: w.want_col, else: c)}
    put_win(st, w) |> scroll_into_view()
  end

  defp add_buffer(st, b) do
    %{st | buffers: Map.put(st.buffers, b.id, b), order: st.order ++ [b.id]}
  end

  defp open_path(st, path) do
    case Enum.find(Map.values(st.buffers), &(&1.path == path)) do
      nil ->
        b =
          if File.dir?(path) do
            dired_buffer(path)
          else
            try do
              Buffer.from_file(path)
            rescue
              e -> Buffer.new(Path.basename(path), "", path: path, meta: %{error: Exception.message(e)})
            end
          end

        st = add_buffer(st, b)
        if File.exists?(path) or b.kind == :dired, do: st, else: msg(st, "(New file)")

      _existing ->
        st
    end
  end

  defp buffer_for_path(st, path), do: Enum.find(Map.values(st.buffers), &(&1.path == path))

  defp show_buffer(st, id) do
    w = win(st)
    prev = w.buf
    st = put_win(st, %{w | buf: id, cursor: Map.get(st.buffers[id].meta, :cursor, {0, 0}), top: 0, left: 0})
    st = if prev != id, do: %{st | prev_buffer: prev}, else: st
    set_cursor(st, cursor(st))
  end

  defp visit(st, path) do
    st = open_path(st, path)
    b = buffer_for_path(st, path)
    show_buffer(st, b.id)
  end

  defp text_rows(st) do
    {rows, _} = st.size
    max(rows - 1, 2)
  end

  @doc "Window rectangles: %{win_id => {row, col, height, width}} (height includes mode line)."
  def rects(st) do
    {_rows, cols} = st.size
    layout = if st.maximized, do: {:leaf, st.maximized}, else: st.layout
    rects(layout, {0, 0, text_rows(st), cols}, %{})
  end

  defp rects({:leaf, id}, rect, acc), do: Map.put(acc, id, rect)

  defp rects({:split, dir, children}, {r, c, h, w}, acc) do
    n = length(children)

    children
    |> Enum.with_index()
    |> Enum.reduce(acc, fn {child, i}, acc ->
      rect =
        case dir do
          :right ->
            cw = div(w - (n - 1), n)
            extra = if i == n - 1, do: w - (n - 1) - cw * n, else: 0
            {r, c + i * (cw + 1), h, cw + extra}

          :below ->
            ch = div(h, n)
            extra = if i == n - 1, do: h - ch * n, else: 0
            {r + i * ch, c, ch + extra, w}
        end

      rects(child, rect, acc)
    end)
  end

  defp view_height(st, id \\ nil) do
    {_, _, h, _} = Map.get(rects(st), id || st.active, {0, 0, text_rows(st), 80})
    max(h - 1, 1)
  end

  defp view_width(st) do
    {_, _, _, w} = Map.get(rects(st), st.active, {0, 0, 0, 80})
    max(w - gutter(st), 1)
  end

  def gutter(st) do
    if st.vars["line-numbers"] do
      digits = buf(st) |> Buffer.line_count() |> Integer.to_string() |> String.length()
      max(digits, 3) + 1
    else
      0
    end
  end

  defp scroll_into_view(st) do
    w = win(st)
    {l, c} = w.cursor
    h = view_height(st)
    b = buf(st)

    top =
      if MapSet.size(b.folds) == 0 do
        cond do
          l < w.top -> l
          l >= w.top + h -> l - h + 1
          true -> w.top
        end
      else
        top = Fold.shown(Fold.hidden(b), min(w.top, Buffer.line_count(b) - 1))

        cond do
          l < top -> l
          Fold.visible_between(b, top, l) >= h -> Fold.step(b, l, -(h - 1))
          true -> top
        end
      end

    vw = view_width(st)
    dc = display_col(Buffer.line(buf(st), l), c)
    left = cond do
      dc < w.left -> dc
      dc >= w.left + vw -> dc - vw + 1
      true -> w.left
    end

    put_win(st, %{w | top: top, left: left})
  end

  def display_col(line, col) do
    line |> String.slice(0, col) |> String.graphemes() |> Enum.reduce(0, fn
      "\t", acc -> acc + 8 - rem(acc, 8)
      g, acc -> acc + Lepton.Width.grapheme(g)
    end)
  end

  # -- folding (Org) -----------------------------------------------------------------------

  defp fold_with(st, f) do
    b = buf(st)
    if Fold.outline?(b), do: st |> put_buf(f.(b)) |> set_cursor(cursor(st)), else: msg(st, "No outline to fold in #{b.mode} mode")
  end

  defp fold_here(st, f) do
    b = buf(st)

    case Fold.heading_at(b, elem(cursor(st), 0)) do
      nil -> fold_with(st, & &1)
      h -> st |> put_buf(f.(b, h)) |> set_cursor(cursor(st))
    end
  end

  # -- normal state ------------------------------------------------------------------------

  # with-editor in a commit message buffer (Spacemacs): `, c` / `, ,` /
  # `C-c C-c` commit, `, a` / `, k` / `C-c C-k` cancel.
  @commit_normal %{
    [",", "c"] => :commit_finish, [",", ","] => :commit_finish, ["C-c", "C-c"] => :commit_finish,
    [",", "a"] => :commit_cancel, [",", "k"] => :commit_cancel, ["C-c", "C-k"] => :commit_cancel
  }
  @commit_insert %{["C-c", "C-c"] => :commit_finish, ["C-c", "C-k"] => :commit_cancel}

  defp normal_key(st, key) do
    cond do
      st.pending == [] and st.operator == nil and key == "q" and st.macro_rec != nil ->
        stop_macro(st)

      st.pending == [] and st.operator == nil and key in ["q", "@"] ->
        %{st | macro_pending: if(key == "q", do: :record, else: :play)}

      st.pending == [] and st.operator == nil and key =~ ~r/^[1-9]$/ ->
        %{st | count: key_count(st.count, key)}

      st.pending == [] and st.count != nil and key =~ ~r/^[0-9]$/ ->
        %{st | count: key_count(st.count, key)}

      st.operator != nil ->
        operator_pending(st, key)

      true ->
        seq = st.pending ++ [key]
        table = if buf(st).kind == :commit, do: Map.merge(st.km.normal, @commit_normal), else: st.km.normal

        case Keymap.lookup(table, seq) do
          {:action, action} ->
            st = %{st | pending: []}
            count = st.count
            st = %{st | count: nil}
            start_change_record(st, seq, action) |> do_action(action, count) |> finish_change(action)

          :prefix ->
            %{st | pending: seq}

          :none ->
            normal_motion_or_operator(%{st | pending: []}, seq)
        end
    end
  end

  # The key after r (the character to put in) or C-q (to insert as it is);
  # `.` repeats r with the same character.
  defp awaited(st, key) do
    st = awaited_key(%{st | awaiting: nil}, st.awaiting, key)
    if st.mode == :normal and st.recording, do: %{st | last_change: st.recording, recording: nil}, else: st
  end

  defp awaited_key(st, :quoted_insert, key) when is_binary(key), do: self_insert(st, Keys.encode(key))

  defp awaited_key(st, {:replace_char, n}, key) when is_binary(key) do
    case Keys.text(key) do
      nil ->
        st

      ch ->
        {l, c} = cursor(st)
        len = Buffer.line_length(buf(st), l)
        n = min(n || 1, len - c)

        if n <= 0 do
          st
        else
          st = snapshot(st)
          {b, _} = Buffer.delete_range(buf(st), {l, c}, {l, c + n})
          {b, _} = Buffer.insert(b, {l, c}, String.duplicate(ch, n))
          st |> put_buf(b) |> set_cursor({l, c + n - 1})
        end
    end
  end

  defp awaited_key(st, {:block_replace, blk}, key) when is_binary(key) do
    case Keys.text(key) do
      nil ->
        st

      ch ->
        {st, _} = map_block(st, blk, fn line, {a, z} -> {String.slice(line, 0, a) <> String.duplicate(ch, z - a) <> String.slice(line, z..-1//1), nil} end)
        block_top_left(st, blk)
    end
  end

  defp awaited_key(st, :select_register, key) when is_binary(key) do
    if key =~ ~r/^[a-zA-Z0-9"_+*]$/, do: %{st | use_register: key}, else: st
  end

  defp awaited_key(st, :set_mark, key) when is_binary(key) do
    cond do
      key =~ ~r/^[a-z]$/ ->
        b = buf(st)
        put_buf(st, %{b | marks: Map.put(b.marks, key, cursor(st))})

      key =~ ~r/^[A-Z]$/ ->
        b = buf(st)
        st = put_buf(st, %{b | marks: Map.put(b.marks, key, cursor(st))})
        # (one file holds each uppercase mark)
        st = Enum.reduce(st.buffers, st, fn {id, ob}, st -> if id != b.id and Map.has_key?(ob.marks, key), do: %{st | buffers: Map.put(st.buffers, id, %{ob | marks: Map.delete(ob.marks, key)})}, else: st end)
        %{st | global_marks: Map.put(st.global_marks, key, b.id)}

      # m' (or m`): set the place '' returns to.
      key in ["'", "`"] ->
        push_jump(st)

      true ->
        st
    end
  end

  defp awaited_key(st, _, _), do: st

  # -- keyboard macros (evil: q, @, @@) -----------------------------------------------------

  # The key after `q` or `@`: a register (a-z, 0-9; `qA` appends to a),
  # or `@` after `@` for the last macro played. Anything else cancels.
  defp macro_key(st, key) do
    kind = st.macro_pending
    count = st.count || 1
    st = %{st | macro_pending: nil, count: nil}

    cond do
      kind == :record and key =~ ~r/^[a-z0-9]$/ ->
        %{st | macro_rec: {key, []}} |> msg("Recording @#{key}")

      kind == :record and key =~ ~r/^[A-Z]$/ ->
        reg = String.downcase(key)
        # (onto the macro as last saved: another le may have recorded it since)
        saved = if st.macros_file, do: Lepton.Editor.Macros.load(st.macros_file)[reg]
        base = saved || Map.get(st.macros, reg, [])
        %{st | macro_rec: {reg, Enum.reverse(base)}} |> msg("Recording @#{reg} (appending)")

      kind == :play and (key =~ ~r/^[a-z0-9]$/ or key =~ ~r/^[A-Z]$/ or key == "@") ->
        reg = if key == "@", do: st.last_macro, else: String.downcase(key)
        play_macro(st, reg, count)

      true ->
        st
    end
  end

  defp stop_macro(st) do
    {reg, keys} = st.macro_rec
    # The q that stopped it was taken too.
    keys = keys |> tl() |> Enum.reverse()
    st = %{st | macro_rec: nil, macros: Map.put(st.macros, reg, keys)}

    # Kept for the next sessions too.
    case st.macros_file && Lepton.Editor.Macros.save(st.macros_file, reg, keys) do
      {:error, why} -> msg(st, "Recorded @#{reg} (#{length(keys)} keys), not saved: #{:file.format_error(why)}", true)
      _ -> msg(st, "Recorded @#{reg} (#{length(keys)} keys)")
    end
  end

  @max_macro_depth 20

  defp play_macro(st, nil, _), do: msg(st, "No macro played yet (@@ repeats the last @x)", true)

  defp play_macro(st, reg, count) do
    st = if st.macros[reg] == nil && st.macros_file, do: %{st | macros: Map.merge(Lepton.Editor.Macros.load(st.macros_file), st.macros)}, else: st

    case st.macros[reg] do
      nil ->
        msg(st, "Register #{reg} has no macro (record one with q#{reg} ... q)", true)

      _ when st.macro_depth >= @max_macro_depth ->
        msg(st, "Macro @#{reg} calls itself too deeply", true)

      keys ->
        # As in Vim: a motion that fails (j on the last line, f finding
        # nothing) stops the macro, the repeats a count asked for, and the
        # macros that called it.
        outer? = st.macro_depth == 0
        st = %{st | last_macro: reg, macro_depth: st.macro_depth + 1, motion_failed: if(outer?, do: false, else: st.motion_failed)}

        st =
          Enum.reduce_while(1..count, st, fn _, st ->
            st = Enum.reduce_while(keys, st, fn key, st -> if st.motion_failed, do: {:halt, st}, else: {:cont, handle_key(st, key)} end)
            if st.motion_failed, do: {:halt, st}, else: {:cont, st}
          end)

        st = %{st | macro_depth: st.macro_depth - 1}
        if outer? and st.motion_failed, do: %{st | motion_failed: false} |> msg("Macro @#{reg} stopped: a motion couldn't move"), else: st
    end
  end

  defp key_count(nil, d), do: String.to_integer(d)
  defp key_count(n, d), do: n * 10 + String.to_integer(d)

  @operators %{"d" => :delete, "c" => :change, "y" => :yank, ">" => :indent, "<" => :dedent, "=" => :reindent, "g~" => :toggle_case, "gu" => :downcase, "gU" => :upcase}

  defp normal_motion_or_operator(st, seq) do
    op_key = Enum.join(seq)

    cond do
      Map.has_key?(@operators, op_key) ->
        %{st | operator: @operators[op_key], op_count: st.count, count: nil, recording: if(st.replaying, do: nil, else: seq)}

      true ->
        case Motion.parse(seq) do
          {:motion, m} -> move(st, m) |> Map.put(:count, nil)
          :more -> %{st | pending: seq}
          _ -> %{st | count: nil}
        end
    end
  end

  # Motions relative to the cursor fail where they can't go (j on the last
  # line, l at the end of one, f without the character): that ends a macro.
  @relative_motions ~w[j k h l <up> <down> <left> <right> + - w W b B e E ge gE { } ( ) n N ; ,]

  # An uppercase mark set in another file: that file, at the mark.
  defp move(st, {k, name} = m) when k in ["'", "`"] and name in ~w(A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do
    id = st.global_marks[name]

    cond do
      id == nil or not Map.has_key?(st.buffers, id) -> msg(st, "Mark not set: #{name}", true)
      id == buf(st).id -> move_to(st, m)
      true -> st |> push_jump() |> show_buffer(id) |> move_to(m)
    end
  end

  defp move(st, {k, name} = m) when k in ["'", "`"] do
    if Map.has_key?(marks(st), name), do: move_to(st, m), else: msg(st, "Mark not set: #{name}", true)
  end

  defp move(st, m) do
    from = cursor(st)
    st = move_to(st, m)
    relative? = m in @relative_motions or match?({k, _} when k in ["f", "F", "t", "T"], m)
    if relative? and cursor(st) == from, do: %{st | motion_failed: true}, else: st
  end

  defp move_to(st, m) do
    {target, kind} = Motion.apply(buf(st), cursor(st), m, st.count, motion_ctx(st))
    st = remember_find(st, m)

    case kind do
      :none -> st
      :linewise when m in ["j", "k", "<up>", "<down>"] ->
        b = buf(st)
        {l, _} = target
        # Folded subtrees count as one line.
        l = if MapSet.size(b.folds) == 0, do: l, else: Fold.step(b, elem(cursor(st), 0), (st.count || 1) * if(m in ["j", "<down>"], do: 1, else: -1))
        w = win(st)
        set_cursor(st, {l, w.want_col}, keep_want: true)

      _ ->
        st = if m in ["G", "gg", "n", "N", "%", "{", "}"] or match?({k, _} when k in ["'", "`"], m), do: push_jump(st), else: st
        set_cursor(st, target, reveal: m in ["n", "N"])
    end
  end

  defp remember_find(st, {k, ch}) when k in ["f", "F", "t", "T"], do: %{st | last_find: {k, ch}}
  defp remember_find(st, _), do: st

  defp motion_ctx(st) do
    w = win(st)
    %{view: {w.top, view_height(st)}, last_find: st.last_find, search: st.search, marks: marks(st)}
  end

  # The marks ' and ` go to: the buffer's, the uppercase ones that are in it,
  # '' (where the last jump left from) and '< '> (the last visual selection).
  defp marks(st) do
    b = buf(st)
    w = win(st)
    special = if w.jumps != [], do: %{"'" => hd(w.jumps), "`" => hd(w.jumps)}, else: %{}

    special =
      case st.last_visual do
        {_, a, z} -> Map.merge(special, %{"<" => min(a, z), ">" => max(a, z)})
        _ -> special
      end

    Map.merge(b.marks, special)
  end

  defp push_jump(st) do
    w = win(st)
    put_win(st, %{w | jumps: Enum.take([w.cursor | w.jumps], 50)})
  end

  # -- operators --------------------------------------------------------------------------

  defp operator_pending(st, key) do
    seq = st.pending ++ [key]
    op_keys = operator_keys(st.operator)

    cond do
      st.pending == [] and key =~ ~r/^[1-9]$/ ->
        %{st | count: key_count(st.count, key)}

      st.pending == [] and st.count != nil and key =~ ~r/^[0-9]$/ ->
        %{st | count: key_count(st.count, key)}

      key in ["ESC", "C-g"] ->
        %{st | operator: nil, pending: [], count: nil, op_count: nil, recording: nil}

      Enum.join(seq) in op_keys ->
        # dd, cc, yy, >>, <<
        n = (st.op_count || 1) * (st.count || 1)
        {l, _} = cursor(st)
        last = min(l + n - 1, Buffer.line_count(buf(st)) - 1)
        apply_operator(st, {l, 0}, {last, 0}, :linewise)

      true ->
        count = if st.op_count || st.count, do: (st.op_count || 1) * (st.count || 1), else: nil

        case Motion.parse(seq) do
          :more ->
            %{st | pending: seq}

          {:motion, m} ->
            # cw behaves like ce (vim compatibility)
            m = if st.operator == :change and m == "w", do: "e", else: m
            m = if st.operator == :change and m == "W", do: "E", else: m
            {target, kind} = Motion.apply(buf(st), cursor(st), m, count, motion_ctx(st))
            st = remember_find(st, m)

            if kind == :none do
              reset_op(st)
            else
              {from, to} = order(cursor(st), target)
              {to, kind} = exclusive_adjust(buf(st), from, to, kind, m)
              apply_operator(st, from, to, kind)
            end

          {:object, obj} ->
            case Motion.object(buf(st), cursor(st), obj) do
              {:range, from, to, kind} -> apply_operator(st, from, to, if(kind == :exclusive, do: :exclusive_range, else: kind))
              :none -> reset_op(st)
            end

          # Not a motion: the operator is cancelled, and the key does what it
          # does on its own (y then o opens a line; Vim would drop the o too).
          :invalid when st.pending == [] ->
            st |> reset_op() |> normal_key(key)

          :invalid ->
            reset_op(st)
        end
    end
  end

  # Vim's rules for an exclusive motion that ends at the start of a later
  # line (dw on a line's last word, d}): it ends at the end of the line
  # before instead (dw doesn't take the newline), and if it began at or
  # before its line's first non-blank it's line-wise, except for w and W
  # (:help word), which just stop at the end of the word.
  defp exclusive_adjust(b, {fl, fc}, {tl, 0}, :exclusive, m) when tl > fl do
    if m not in ["w", "W"] and fc <= Motion.first_non_blank(b, fl),
      do: {{tl - 1, 0}, :linewise},
      else: {{tl - 1, Buffer.line_length(b, tl - 1)}, :exclusive}
  end

  defp exclusive_adjust(_b, _from, to, kind, _m), do: {to, kind}

  defp operator_keys(:delete), do: ["d"]
  defp operator_keys(:change), do: ["c"]
  defp operator_keys(:yank), do: ["y"]
  defp operator_keys(:indent), do: [">"]
  defp operator_keys(:dedent), do: ["<"]
  defp operator_keys(:reindent), do: ["="]
  defp operator_keys(op) when op in [:toggle_case, :downcase, :upcase], do: ["~", "u", "U", "g~", "gu", "gU"]

  defp reset_op(st), do: %{st | operator: nil, pending: [], count: nil, op_count: nil, recording: nil}

  # The last line of what's hidden right under line `l` (nested folds and
  # all), or `l` when nothing is.
  defp through_folds(%{folds: folds} = b, l) do
    if MapSet.size(folds) == 0 do
      l
    else
      case Enum.find(Fold.hidden(b), &(&1.first == l + 1)) do
        nil -> l
        r -> through_folds(b, r.last)
      end
    end
  end

  defp through_folds(_b, l), do: l

  defp order(a, b) when a <= b, do: {a, b}
  defp order(a, b), do: {b, a}

  # Ranges: :linewise uses whole lines from..to; :inclusive includes `to`;
  # :exclusive excludes it; :exclusive_range is an already-exclusive end.
  defp apply_operator(st, {fl, fc} = from, {tl, tc} = to, kind) do
    # A closed fold is one line to a linewise operator, as in Vim: ending
    # on a folded heading takes the lines hidden under it too (`Vd`, `dd`,
    # `yy`, `>>` on a folded org heading act on the whole subtree; before,
    # only the heading's line went, and its body was left behind).
    {tl, to} = if kind == :linewise, do: (fn t -> {t, {t, tc}} end).(through_folds(buf(st), tl)), else: {tl, to}
    op = st.operator
    st = %{st | operator: nil, pending: [], count: nil, op_count: nil}
    # Take the undo snapshot before reading the buffer we modify.
    st = if op == :yank, do: st, else: snapshot(st)
    b = buf(st)

    st =
      case kind do
        :linewise ->
          case op do
            :yank ->
              st = set_register(st, {:line, Buffer.get_lines(b, fl, tl)}, :yank)
              msg(st, if(tl > fl, do: "#{tl - fl + 1} lines yanked", else: nil))

            :delete ->
              {b, deleted} = Buffer.delete_lines(b, fl, tl)
              st = st |> put_buf(b) |> set_register({:line, deleted})
              set_cursor(st, {min(fl, Buffer.line_count(b) - 1), 0}) |> then(&set_cursor(&1, {elem(cursor(&1), 0), Motion.first_non_blank(buf(&1), elem(cursor(&1), 0))}))

            :change ->
              indent = Buffer.line(b, fl) |> then(&String.slice(&1, 0, Motion.first_non_blank(b, fl)))
              {b, deleted} = Buffer.delete_lines(b, fl, tl)
              b = Buffer.insert_lines(b, fl, [indent])
              st = st |> put_buf(b) |> set_register({:line, deleted})
              enter_insert(set_cursor(%{st | mode: :insert}, {fl, String.length(indent)}), false)

            op when op in [:indent, :dedent, :reindent] ->
              unit = Buffer.indent_unit(b)

              lines =
                for i <- fl..tl do
                  line = Buffer.line(b, i)

                  case op do
                    :indent -> if line == "", do: line, else: unit <> line
                    :dedent -> String.replace_prefix(line, unit, "") |> then(&if(&1 == line, do: String.trim_leading(line), else: &1))
                    :reindent -> line
                  end
                end

              st = put_buf(st, Buffer.replace_lines(b, fl, tl, lines))
              set_cursor(st, {fl, Motion.first_non_blank(buf(st), fl)})

            op ->
              case_lines(st, fl, tl, op)
          end

        _ ->
          to_excl = if kind == :inclusive, do: {tl, tc + 1}, else: to
          text = Buffer.get_range(b, from, to_excl)

          case op do
            :yank ->
              st |> set_register({:char, text}, :yank) |> set_cursor(from)

            :delete ->
              {b, _} = Buffer.delete_range(b, from, to_excl)
              st |> put_buf(b) |> set_register({:char, text}) |> set_cursor(from)

            :change ->
              {b, _} = Buffer.delete_range(b, from, to_excl)
              st = st |> put_buf(b) |> set_register({:char, text})
              enter_insert(set_cursor(%{st | mode: :insert}, from), false)

            op when op in [:indent, :dedent, :reindent] ->
              %{st | operator: op} |> apply_operator({fl, 0}, {tl, 0}, :linewise)

            op ->
              {b, _} = Buffer.delete_range(b, from, to_excl)
              {b, _} = Buffer.insert(b, from, recase(text, op))
              st |> put_buf(b) |> set_cursor(from)
          end
      end

    _ = fc
    finish_op_record(st)
  end

  defp case_lines(st, fl, tl, op) do
    b = buf(st)
    lines = for i <- fl..tl, do: recase(Buffer.line(b, i), op)
    put_buf(st, Buffer.replace_lines(b, fl, tl, lines))
  end

  defp recase(text, :upcase), do: String.upcase(text)
  defp recase(text, :downcase), do: String.downcase(text)

  defp recase(text, :toggle_case) do
    text |> String.graphemes() |> Enum.map_join(fn g -> if g == String.upcase(g), do: String.downcase(g), else: String.upcase(g) end)
  end

  defp set_register(st, reg, how \\ :delete) do
    name = st.use_register
    st = %{st | use_register: nil}

    if name == "_" do
      # the black hole: nothing kept, the unnamed register as it was
      st
    else
      {st, reg} =
        cond do
          name != nil and name =~ ~r/^[A-Z]$/ ->
            key = String.downcase(name)
            all = append_register(st.registers[key], reg)
            {%{st | registers: Map.put(st.registers, key, all)}, all}

          name != nil and name =~ ~r/^[a-z0-9]$/ ->
            {%{st | registers: Map.put(st.registers, name, reg)}, reg}

          true ->
            {st, reg}
        end

      st = if how == :yank, do: %{st | registers: Map.put(st.registers, "0", reg)}, else: st
      text = register_text(reg)
      if text != "", do: Lepton.Clipboard.put(text)
      %{st | register: reg}
    end
  end

  defp register_text({:line, lines}), do: Enum.join(lines, "\n") <> "\n"
  defp register_text({:char, t}), do: t
  defp register_text({:block, rows}), do: Enum.join(rows, "\n")

  # "A: appended to a; mixed kinds become lines (blocks: rows).
  defp append_register(nil, reg), do: reg
  defp append_register({:char, a}, {:char, b}), do: {:char, a <> b}
  defp append_register({:block, a}, {:block, b}), do: {:block, a ++ b}
  defp append_register({:block, a}, other), do: {:block, a ++ register_lines(other)}
  defp append_register(a, b), do: {:line, register_lines(a) ++ register_lines(b)}

  defp register_lines({:line, lines}), do: lines
  defp register_lines({:char, t}), do: String.split(t, "\n")
  defp register_lines({:block, rows}), do: rows

  # What a paste takes: the register " chose (the clipboard for "+ and "*),
  # else the unnamed one. nil for an empty one.
  defp register_for(%{use_register: nil} = st), do: st.register
  defp register_for(%{use_register: "_"}), do: nil

  defp register_for(%{use_register: name}) when name in ["+", "*"] do
    case Lepton.Clipboard.get() do
      "" -> nil
      text -> if String.ends_with?(text, "\n"), do: {:line, String.split(String.trim_trailing(text, "\n"), "\n")}, else: {:char, text}
    end
  end

  defp register_for(%{use_register: "\""} = st), do: st.register
  defp register_for(st), do: st.registers[String.downcase(st.use_register)]

  # -- change recording (for `.`) ------------------------------------------------------------

  @changing ~w(insert append insert_bol append_eol open_below open_above delete_char delete_char_before
               substitute_char substitute_line delete_eol change_eol paste_after paste_before join_lines
               replace_char toggle_case)a

  defp start_change_record(%{replaying: true} = st, _seq, _a), do: st
  defp start_change_record(st, seq, action) when action in @changing, do: %{st | recording: seq}
  defp start_change_record(st, _seq, _a), do: st

  # (r waits for its character: the change ends with it, in awaited/3)
  defp finish_change(%{awaiting: a} = st, _action) when a != nil, do: st

  defp finish_change(st, action) when action in @changing do
    if st.mode == :normal and st.recording, do: %{st | last_change: st.recording, recording: nil}, else: st
  end

  defp finish_change(st, _), do: st

  defp finish_op_record(st) do
    if st.mode == :normal and st.recording, do: %{st | last_change: st.recording, recording: nil}, else: st
  end

  defp snapshot(st) do
    b = buf(st)
    put_buf(st, Buffer.snapshot(b, cursor(st)))
  end

  # -- actions -------------------------------------------------------------------------------

  @doc false
  def do_action(st, action, count \\ nil)

  def do_action(st, :insert, _), do: enter_insert(st)
  def do_action(st, :append, _), do: enter_insert(st) |> then(fn st -> {l, c} = cursor(st); if Buffer.line_length(buf(st), l) > 0, do: set_cursor(st, {l, c + 1}), else: st end)
  def do_action(st, :insert_bol, _), do: enter_insert(st) |> then(&set_cursor(&1, {elem(cursor(&1), 0), Motion.first_non_blank(buf(&1), elem(cursor(&1), 0))}))
  def do_action(st, :append_eol, _), do: enter_insert(st) |> then(&set_cursor(&1, {elem(cursor(&1), 0), Buffer.line_length(buf(&1), elem(cursor(&1), 0))}))

  def do_action(st, :commit_finish, _), do: st |> exit_insert_if_needed() |> save() |> close_commit()
  def do_action(st, :commit_cancel, _), do: st |> exit_insert_if_needed() |> close_commit() |> msg("Commit canceled")

  def do_action(st, :open_below, _) do
    st = snapshot(st)
    {l, _} = cursor(st)
    b = buf(st)
    indent = leading(Buffer.line(b, l))
    # On a folded heading, below its subtree (as in Emacs and vim).
    at = if MapSet.size(b.folds) == 0, do: l + 1, else: Fold.visible_at_or_after(Fold.hidden(b), l + 1, Buffer.line_count(b)) || Buffer.line_count(b)
    st = put_buf(st, Buffer.insert_lines(b, at, [indent]))
    enter_insert(%{st | mode: :insert} |> set_cursor({at, String.length(indent)}), false)
  end

  def do_action(st, :open_above, _) do
    st = snapshot(st)
    {l, _} = cursor(st)
    indent = leading(Buffer.line(buf(st), l))
    st = put_buf(st, Buffer.insert_lines(buf(st), l, [indent]))
    enter_insert(%{st | mode: :insert} |> set_cursor({l, String.length(indent)}), false)
  end

  def do_action(st, :delete_char, n) do
    {l, c} = cursor(st)
    len = Buffer.line_length(buf(st), l)

    if len == 0 do
      st
    else
      st = snapshot(st)
      {b, text} = Buffer.delete_range(buf(st), {l, c}, {l, min(c + (n || 1), len)})
      st |> put_buf(b) |> set_register({:char, text}) |> set_cursor({l, c})
    end
  end

  def do_action(st, :delete_char_before, n) do
    {l, c} = cursor(st)

    if c == 0 do
      st
    else
      st = snapshot(st)
      from = max(c - (n || 1), 0)
      {b, text} = Buffer.delete_range(buf(st), {l, from}, {l, c})
      st |> put_buf(b) |> set_register({:char, text}) |> set_cursor({l, from})
    end
  end

  def do_action(st, :substitute_char, n), do: st |> do_action(:delete_char, n) |> then(&enter_insert(&1, false))
  def do_action(st, :substitute_line, _), do: %{st | operator: :change} |> apply_operator({elem(cursor(st), 0), 0}, {elem(cursor(st), 0), 0}, :linewise)
  def do_action(st, :delete_eol, _), do: %{st | operator: :delete} |> apply_operator(cursor(st), {elem(cursor(st), 0), Buffer.line_length(buf(st), elem(cursor(st), 0))}, :exclusive_range)
  def do_action(st, :change_eol, _), do: %{st | operator: :change} |> apply_operator(cursor(st), {elem(cursor(st), 0), Buffer.line_length(buf(st), elem(cursor(st), 0))}, :exclusive_range)
  def do_action(st, :yank_line, n), do: %{st | operator: :yank} |> apply_operator({elem(cursor(st), 0), 0}, {min(elem(cursor(st), 0) + (n || 1) - 1, Buffer.line_count(buf(st)) - 1), 0}, :linewise)

  def do_action(st, :paste_after, n), do: paste(st, :after, n || 1)
  def do_action(st, :paste_before, n), do: paste(st, :before, n || 1)

  def do_action(st, :undo, _) do
    {b, c} = Buffer.undo(buf(st), cursor(st))
    if c, do: st |> put_buf(b) |> set_cursor(c), else: msg(st, "Already at oldest change")
  end

  def do_action(st, :redo, _) do
    {b, c} = Buffer.redo(buf(st), cursor(st))
    if c, do: st |> put_buf(b) |> set_cursor(c), else: msg(st, "Already at newest change")
  end

  def do_action(st, :join_lines, n), do: join(st, n || 2, true)
  def do_action(st, :join_lines_raw, n), do: join(st, n || 2, false)

  # The character comes as the next key (so macros record and play it).
  def do_action(st, :replace_char, n), do: %{st | awaiting: {:replace_char, n}}
  # m and a letter: a mark here (the next key is its name).
  def do_action(st, :set_mark, _), do: %{st | awaiting: :set_mark}
  # " and a name: the register the next yank, delete or paste uses (the count stays).
  def do_action(st, :select_register, n), do: %{st | awaiting: :select_register, count: n}

  def do_action(st, :list_registers, _) do
    show = fn reg -> reg |> register_text() |> String.replace("\n", "^J") |> String.slice(0, 30) end
    named = for {k, reg} <- Enum.sort(st.registers), do: "\"#{k} #{show.(reg)}"
    msg(st, Enum.join(["\"\" #{show.(st.register)}" | named], "  "))
  end

  def do_action(st, :list_marks, _) do
    b = buf(st)
    here = for {k, {l, c}} <- Enum.sort(b.marks), k =~ ~r/^[a-z]$/, do: "#{k} #{l + 1}:#{c}"
    there = for {k, id} <- Enum.sort(st.global_marks), mb = st.buffers[id], {l, c} = mb.marks[k] || {0, 0}, do: "#{k} #{mb.name}:#{l + 1}:#{c}"
    msg(st, if(here ++ there == [], do: "No marks set", else: "Marks: " <> Enum.join(here ++ there, "  ")))
  end

  def do_action(st, :replace_mode, _), do: enter_insert(%{st | mode: :replace}, true) |> Map.put(:mode, :replace)

  def do_action(st, :toggle_case, n) do
    {l, c} = cursor(st)
    len = Buffer.line_length(buf(st), l)
    to = min(c + (n || 1), len)

    if len == 0 do
      st
    else
      st = snapshot(st)
      text = Buffer.get_range(buf(st), {l, c}, {l, to})
      {b, _} = Buffer.delete_range(buf(st), {l, c}, {l, to})
      {b, _} = Buffer.insert(b, {l, c}, recase(text, :toggle_case))
      st |> put_buf(b) |> set_cursor({l, to})
    end
  end

  def do_action(st, :visual, _), do: %{st | mode: :visual, visual_start: cursor(st)}
  def do_action(st, :visual_line, _), do: %{st | mode: :visual_line, visual_start: cursor(st)}
  def do_action(st, :visual_block, _), do: %{st | mode: :visual_block, visual_start: cursor(st), block_eol: false}

  def do_action(st, :reselect_visual, _) do
    case st.last_visual do
      {mode, start, stop} -> %{st | mode: mode, visual_start: start} |> set_cursor(stop)
      nil -> st
    end
  end

  def do_action(st, :repeat, _) do
    keys = st.last_change
    st = Enum.reduce(keys, %{st | replaying: true}, &handle_key(&2, &1))
    %{st | replaying: false, last_change: keys}
  end

  def do_action(st, :ex, _), do: prompt(st, :ex, ":", "")
  def do_action(st, :mx, _), do: prompt(st, :mx, "M-x ", "") |> refresh_candidates()
  def do_action(st, :search_forward, _), do: prompt(st, {:search, 1}, "/", "")
  def do_action(st, :search_backward, _), do: prompt(st, {:search, -1}, "?", "")
  def do_action(st, :search_next, n), do: move(%{st | count: n}, "n") |> search_feedback()
  def do_action(st, :search_previous, n), do: move(%{st | count: n}, "N") |> search_feedback()
  def do_action(st, :search_word_forward, n), do: search_word(st, 1, n)
  def do_action(st, :search_word_backward, n), do: search_word(st, -1, n)
  def do_action(st, :clear_highlight, _), do: st

  def do_action(st, :scroll_line_to_center, _), do: scroll_to(st, :center)
  def do_action(st, :scroll_line_to_top, _), do: scroll_to(st, :top)
  def do_action(st, :scroll_line_to_bottom, _), do: scroll_to(st, :bottom)
  def do_action(st, :scroll_half_down, _), do: scroll_by(st, div(view_height(st), 2))
  def do_action(st, :scroll_half_up, _), do: scroll_by(st, -div(view_height(st), 2))
  def do_action(st, :page_down, _), do: scroll_by(st, view_height(st) - 2)
  def do_action(st, :page_up, _), do: scroll_by(st, -(view_height(st) - 2))

  def do_action(st, :scroll_line_down, _) do
    w = win(st)
    st = put_win(st, %{w | top: min(w.top + 1, Buffer.line_count(buf(st)) - 1)})
    {l, c} = cursor(st)
    if l < win(st).top, do: set_cursor(st, {win(st).top, c}), else: st
  end

  def do_action(st, :scroll_line_up, _) do
    w = win(st)
    st = put_win(st, %{w | top: max(w.top - 1, 0)})
    {l, c} = cursor(st)
    if l >= win(st).top + view_height(st), do: set_cursor(st, {win(st).top + view_height(st) - 1, c}), else: st
  end

  def do_action(st, :jump_back, _) do
    w = win(st)

    case w.jumps do
      [pos | rest] -> put_win(st, %{w | jumps: rest}) |> set_cursor(pos)
      [] -> st
    end
  end

  def do_action(st, :keyboard_quit, _), do: %{st | pending: [], count: nil, operator: nil, use_register: nil} |> msg("Quit")
  def do_action(st, :redraw, _), do: %{st | frame: []}

  def do_action(st, :org_cycle, _) do
    b = buf(st)
    h = Fold.outline?(b) && Fold.heading?(b, elem(cursor(st), 0)) && elem(cursor(st), 0)
    if h, do: (fn {b, state} -> st |> put_buf(b) |> set_cursor(cursor(st)) |> msg(state) end).(Fold.cycle(b, h)), else: st
  end

  def do_action(st, :org_global_cycle, _) do
    b = buf(st)
    if Fold.outline?(b), do: (fn {b, state} -> st |> put_buf(b) |> set_cursor(cursor(st)) |> msg(state) end).(Fold.global_cycle(b)), else: st
  end

  def do_action(st, :fold_all, _), do: fold_with(st, &Fold.fold_all/1)
  def do_action(st, :unfold_all, _), do: fold_with(st, &Fold.unfold_all/1)
  def do_action(st, :fold_close, _), do: fold_here(st, &Fold.fold/2)
  def do_action(st, :fold_open, _), do: fold_here(st, &Fold.unfold/2)
  def do_action(st, :fold_toggle, _), do: fold_here(st, fn b, h -> if MapSet.member?(b.folds, h), do: Fold.unfold(b, h), else: Fold.fold(b, h) end)
  def do_action(st, :normal_state, _), do: %{st | mode: :normal}

  # files
  def do_action(st, :save, _), do: save(st)

  # SPC f S, C-x s, :wa: every changed buffer that has a file (after a project replace, say).
  def do_action(st, :save_all, _) do
    changed = for id <- st.order, b = st.buffers[id], b.modified and b.path, do: b
    st = Enum.reduce(changed, st, fn b, st -> save_buffer(st, b) |> elem(1) end)
    n = length(changed)

    case n do
      0 -> msg(st, "No changed files to save")
      _ -> msg(st, "Saved #{n} file#{if n == 1, do: "", else: "s"}: #{Enum.map_join(changed, ", ", & &1.name)}")
    end
  end

  def do_action(st, :find_file, _), do: prompt(st, :find_file, "Find file: ", dir_of(st) <> "/") |> refresh_candidates()
  def do_action(st, :project_find_file, _), do: prompt(st, :project_file, "Find file in project: ", "") |> refresh_candidates()
  def do_action(st, :recent_files, _), do: prompt(st, :switch_buffer, "Recent: ", "") |> refresh_candidates()
  def do_action(st, :switch_buffer, _), do: prompt(st, :switch_buffer, "Switch to buffer: ", "") |> refresh_candidates()
  def do_action(st, :dired_jump, _), do: visit(st, dir_of(st))
  def do_action(st, :show_file_name, _), do: msg(st, buf(st).path || buf(st).name)
  def do_action(st, :rename_file, _), do: prompt(st, :rename_file, "Rename to: ", buf(st).path || "")
  def do_action(st, :delete_file, _), do: prompt(st, :confirm_delete, "Delete #{buf(st).name}? (y or n) ", "")
  def do_action(st, :open_dotfile, _), do: visit(st, Path.join(Lepton.Ctx.home(st.ctx), ".spacemacs"))
  def do_action(st, :revert_buffer, _), do: revert(st)

  def do_action(st, :kill_buffer, _), do: kill_buffer(st, win(st).buf)
  def do_action(st, :next_buffer, _), do: cycle_buffer(st, 1)
  def do_action(st, :previous_buffer, _), do: cycle_buffer(st, -1)
  def do_action(st, :last_buffer, _), do: if(st.prev_buffer && st.buffers[st.prev_buffer], do: show_buffer(st, st.prev_buffer), else: st)

  def do_action(st, :scratch_buffer, _) do
    case Enum.find(Map.values(st.buffers), &(&1.kind == :scratch)) do
      nil -> st |> add_buffer(Buffer.new("*scratch*", "", kind: :scratch)) |> then(&show_buffer(&1, List.last(&1.order)))
      b -> show_buffer(st, b.id)
    end
  end

  def do_action(st, :messages_buffer, _), do: special_buffer(st, "*Messages*", :help, Enum.join(Enum.reverse(st.messages), "\n"))

  # search
  def do_action(st, :swoop, _), do: prompt(st, :swoop, "Swoop: ", "") |> refresh_candidates()
  def do_action(st, :search_project, _), do: prompt(st, :grep, "Search project: ", "")
  # SPC p R (projectile-replace): text to find, what replaces it, then each match asks.
  def do_action(st, :project_replace, _), do: prompt(st, {:replace_from, :literal, :project}, "Replace in project: ", "")
  # SPC p % (projectile-replace-regexp): the same with a regexp (\1 ... in the replacement).
  def do_action(st, :project_replace_regexp, _), do: prompt(st, {:replace_from, :regexp, :project}, "Replace regexp in project: ", "")
  # SPC s R / SPC s %: the same in a directory you name (this file's to start
  # with), every file under it: what git ignores, dotfiles, _build too (not .git).
  def do_action(st, :directory_replace, _), do: prompt(st, {:replace_dir, :literal}, "Replace in directory: ", dir_of(st) <> "/")
  def do_action(st, :directory_replace_regexp, _), do: prompt(st, {:replace_dir, :regexp}, "Replace regexp in directory: ", dir_of(st) <> "/")

  # windows
  def do_action(st, :split_right, _), do: split(st, :right)
  def do_action(st, :split_below, _), do: split(st, :below)
  def do_action(st, :delete_window, _), do: delete_window(st, st.active)
  def do_action(st, :maximize_window, _), do: %{st | maximized: if(st.maximized, do: nil, else: st.active), frame: []}
  def do_action(st, :balance_windows, _), do: %{st | maximized: nil, frame: []}
  def do_action(st, :other_window, _), do: other_window(st)
  def do_action(st, :window_left, _), do: window_move(st, :left)
  def do_action(st, :window_right, _), do: window_move(st, :right)
  def do_action(st, :window_up, _), do: window_move(st, :up)
  def do_action(st, :window_down, _), do: window_move(st, :down)

  def do_action(st, {:select_window, n}, _) do
    ids = st.layout |> leaves()
    case Enum.at(ids, n - 1) do
      nil -> msg(st, "No window numbered #{n}", true)
      id -> select_window(st, id)
    end
  end

  # toggles
  def do_action(st, :toggle_line_numbers, _), do: toggle(st, "line-numbers")
  def do_action(st, :toggle_fill_column, _), do: toggle(st, "fill-column-indicator")
  def do_action(st, :toggle_truncate, _), do: toggle(st, "truncate-lines")
  def do_action(st, :toggle_whitespace, _), do: toggle(st, "show-whitespace")

  def do_action(st, :toggle_relative, _) do
    v = if st.vars["display-line-numbers-type"] == "relative", do: true, else: "relative"
    %{st | vars: Map.put(st.vars, "display-line-numbers-type", v), frame: []}
  end

  # text
  def do_action(st, :delete_trailing_whitespace, _) do
    st = snapshot(st)
    b = Buffer.delete_trailing_whitespace(buf(st))
    st |> put_buf(b) |> set_cursor(cursor(st)) |> msg("Deleted trailing whitespace")
  end

  def do_action(st, :sort_lines, _) do
    {fl, tl} = region_lines(st)
    st = snapshot(st)
    b = buf(st)
    sorted = b |> Buffer.get_lines(fl, tl) |> Enum.sort()
    %{st | mode: :normal} |> put_buf(Buffer.replace_lines(b, fl, tl, sorted)) |> set_cursor({fl, 0})
  end

  def do_action(st, :align_repeat, _) do
    region = region_lines(st)
    prompt(%{st | mode: :normal}, {:align, region}, "Align regexp: ", "")
  end

  # -- Typst (SPC m c, SPC m p, SPC m w) ------------------------------------------------------

  def do_action(st, :typst_compile, _), do: if(typst?(st), do: st |> save_first() |> typst_compile(:compile), else: not_typst(st))
  def do_action(st, :typst_preview, _), do: if(typst?(st), do: st |> save_first() |> typst_compile(:preview), else: not_typst(st))

  def do_action(st, :typst_toggle_watch, _) do
    on = !st.vars["typst-compile-on-save"]
    msg(%{st | vars: Map.put(st.vars, "typst-compile-on-save", on)}, if(on, do: "Typst: compiling on each save", else: "Typst: not compiling on save (SPC m c compiles)"))
  end

  def do_action(st, :comment_line, n) do
    {fl, tl} = if st.mode in [:visual, :visual_line, :visual_block], do: region_lines(st), else: {elem(cursor(st), 0), elem(cursor(st), 0) + (n || 1) - 1}
    st = snapshot(st)
    b = buf(st)
    prefix = Buffer.comment_prefix(b)
    lines = Buffer.get_lines(b, fl, tl)
    commented? = Enum.all?(lines, &(String.trim(&1) == "" or String.starts_with?(String.trim_leading(&1), String.trim(prefix))))

    new =
      Enum.map(lines, fn line ->
        cond do
          String.trim(line) == "" -> line
          commented? -> Regex.replace(~r/^(\s*)#{Regex.escape(String.trim(prefix))} ?/, line, "\\1")
          true -> leading(line) <> prefix <> String.trim_leading(line)
        end
      end)

    %{st | mode: :normal} |> put_buf(Buffer.replace_lines(b, fl, tl, new)) |> set_cursor(cursor(st))
  end

  def do_action(st, :downcase_region, _), do: visual_case(st, :downcase)
  def do_action(st, :upcase_region, _), do: visual_case(st, :upcase)

  # git / magit / GitHub
  def do_action(st, :magit_status, _), do: Magit.status(st)
  def do_action(st, :magit_log, _), do: Magit.log(st)
  def do_action(st, :git_diff, _), do: Magit.diff(st)

  def do_action(st, :github_browse, _) do
    case Lepton.GH.repo_url(dir_of(st)) do
      {:ok, url} -> msg(st, "GitHub: " <> url)
      _ -> msg(st, "No GitHub remote for this repository", true)
    end
  end

  # help
  def do_action(st, :describe_bindings, _), do: special_buffer(st, "*Help*", :help, Render.describe_bindings(st))
  def do_action(st, :describe_key, _), do: prompt(st, :describe_key, "Describe key: ", "")
  def do_action(st, :describe_variables, _), do: special_buffer(st, "*Help*", :help, Enum.map_join(Enum.sort(st.vars), "\n", fn {k, v} -> "#{k}: #{inspect(v)}" end))
  def do_action(st, :shell_hint, _), do: msg(st, "Use the multiplexer for a shell: C-t v (split) or C-t c (new window)")

  # quitting
  def do_action(st, :quit_all, _) do
    modified = Enum.filter(Map.values(st.buffers), &(&1.modified and &1.kind == :file))
    if modified == [], do: %{st | quit: true}, else: prompt(st, :confirm_quit, "Modified buffers exist; really exit? (y or n) ", "")
  end

  def do_action(st, :quit_all_force, _), do: %{st | quit: true}
  def do_action(st, :quit_force, _), do: quit_window(st, true)
  def do_action(st, :save_quit, _), do: st |> save() |> quit_window(false)

  # insert-only actions reaching here (e.g. through dotfile bindings) are no-ops
  def do_action(st, :goto_definition, _), do: search_word(st, 1, 1)
  def do_action(st, :insert_last, _), do: enter_insert(st)
  def do_action(st, :magit_stash, _), do: Magit.action(st, :magit_stash)
  def do_action(st, action, _) when action in [:next_line, :previous_line], do: move(st, if(action == :next_line, do: "j", else: "k"))
  def do_action(st, action, _), do: msg(st, "#{Keymap.action_label(action)} is not available here")

  defp toggle(st, var), do: %{st | vars: Map.update(st.vars, var, true, &(!&1)), frame: []} |> msg("#{var}: #{if st.vars[var], do: "off", else: "on"}")

  defp leading(line), do: String.slice(line, 0, String.length(line) - String.length(String.trim_leading(line)))

  defp join(st, n, spaces) do
    {l, _} = cursor(st)
    last = min(l + n - 1, Buffer.line_count(buf(st)) - 1)

    if last == l do
      st
    else
      st = snapshot(st)
      b = buf(st)
      lines = Buffer.get_lines(b, l, last)

      joined =
        Enum.reduce(tl(lines), hd(lines), fn line, acc ->
          if spaces do
            t = String.trim_leading(line)
            sep = if acc == "" or t == "" or String.ends_with?(acc, " ") or String.starts_with?(t, ")"), do: "", else: " "
            acc <> sep <> t
          else
            acc <> line
          end
        end)

      col = String.length(hd(lines))
      st |> put_buf(Buffer.replace_lines(b, l, last, [joined])) |> set_cursor({l, col})
    end
  end

  defp paste(st, where, n) do
    case register_for(st) do
      nil -> msg(%{st | use_register: nil}, "Register #{st.use_register} is empty", st.use_register != "_")
      reg -> paste_register(%{st | use_register: nil}, where, n, reg)
    end
  end

  defp paste_register(st, where, n, reg) do
    st = snapshot(st)
    {l, c} = cursor(st)
    b = buf(st)

    empty_line? = Buffer.line(b, l) == ""

    case reg do
      {:line, lines} ->
        lines = List.duplicate(lines, n) |> List.flatten()
        at = if where == :after, do: l + 1, else: l
        st |> put_buf(Buffer.insert_lines(b, at, lines)) |> set_cursor({at, Motion.first_non_blank(Buffer.insert_lines(b, at, lines), at)})

      {:char, text} ->
        text = String.duplicate(text, n)
        pos = if where == :after and Buffer.line_length(b, l) > 0, do: {l, c + 1}, else: {l, c}
        {b, {el, ec}} = Buffer.insert(b, pos, text)
        st |> put_buf(b) |> set_cursor({el, max(ec - 1, 0)})

      # A block on an empty line (after o, say): its rows as lines of their
      # own there, and the empty line after them, keeping it apart from the
      # lines below. (Vim would put the second row in front of the next line.)
      {:block, rows} when empty_line? ->
        rows = Enum.map(rows, &String.duplicate(&1, n))
        st |> put_buf(Buffer.insert_lines(b, l, rows)) |> set_cursor({l, 0})

      # A block: each row at the same column of the next lines (padded, and
      # lines added below the end, as needed).
      {:block, rows} ->
        line = Buffer.line(b, l)
        col = display_col(line, c) + if(where == :after and line != "", do: block_char_width(line, c), else: 0)
        rows = Enum.map(rows, &String.duplicate(&1, n))
        missing = l + length(rows) - Buffer.line_count(b)
        b = if missing > 0, do: Buffer.insert_lines(b, Buffer.line_count(b), List.duplicate("", missing)), else: b
        lines = for {row, i} <- Enum.with_index(rows), do: insert_at_col(Buffer.line(b, l + i), col, row)
        st |> put_buf(Buffer.replace_lines(b, l, l + length(rows) - 1, lines)) |> set_cursor({l, column_at(hd(lines), col)})
    end
  end

  defp search_word(st, dir, n) do
    {l, c} = cursor(st)
    line = Buffer.line(buf(st), l)

    case Motion.object(buf(st), {l, c}, {"i", "w"}) do
      {:range, {_, s}, {_, e}, _} ->
        word = String.slice(line, s, e - s)
        re = Regex.compile!("\\b" <> Regex.escape(word) <> "\\b", "u")
        st = %{st | search: {re, dir}} |> set_cursor({l, s})
        move(%{st | count: n}, "n") |> msg("/" <> word)

      :none ->
        st
    end
  end

  defp search_feedback(st) do
    case st.search do
      {re, _} -> msg(st, "/" <> re.source)
      nil -> msg(st, "No previous search", true)
    end
  end

  defp scroll_to(st, where) do
    w = win(st)
    {l, _} = w.cursor
    h = view_height(st)
    top = case where do
      :center -> max(l - div(h, 2), 0)
      :top -> l
      :bottom -> max(l - h + 1, 0)
    end

    put_win(st, %{w | top: top})
  end

  defp scroll_by(st, n) do
    w = win(st)
    last = Buffer.line_count(buf(st)) - 1
    top = (w.top + n) |> max(0) |> min(max(last - 1, 0))
    {l, c} = w.cursor
    st = put_win(st, %{w | top: top})
    set_cursor(st, {(l + n) |> max(0) |> min(last), c}) |> then(&put_win(&1, %{win(&1) | top: top}))
  end

  defp dir_of(st) do
    case buf(st) do
      %{kind: :dired, meta: %{dir: d}} -> d
      %{path: p} when is_binary(p) -> Path.dirname(p)
      _ -> st.ctx.cwd
    end
  end

  defp typst?(st), do: buf(st).mode == "Typst"

  @typst_starter """
  #set page(paper: "a4")
  #set text(lang: "en")

  = A Title

  Write here. *Strong*, _emphasis_, math: $a^2 + b^2 = c^2$.

  // Saving compiles this into a PDF beside it; SPC m p shows the PDF.
  """

  @doc "A name for a new Typst file in ~/Documents: untitled.typ, untitled-2.typ, ..."
  def untitled_typst(ctx) do
    dir = Path.join(Lepton.Ctx.home(ctx), "Documents")
    Lepton.Users.own_new(ctx, dir, fn -> File.mkdir_p(dir) end)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(&Path.join(dir, if(&1 == 1, do: "untitled.typ", else: "untitled-#{&1}.typ")))
    |> Enum.find(&(not File.exists?(&1)))
  end

  # New (empty, not yet on disk) Typst files get the starter, unsaved.
  defp typst_starter(st) do
    Enum.reduce(st.order, st, fn id, st ->
      b = st.buffers[id]

      if b.mode == "Typst" and b.path && not File.exists?(b.path) and Buffer.text(b) in ["", "\n"] do
        put_buf(st, Buffer.set_lines(b, String.split(String.trim_trailing(@typst_starter), "\n")))
      else
        st
      end
    end)
  end
  defp not_typst(st), do: msg(st, "Not a Typst file (.typ)", true)

  # Compile needs the file as it is on screen: save it first (that compiles
  # too, with compile-on-save; once is enough).
  defp save_first(st) do
    b = buf(st)

    cond do
      b.path == nil -> prompt(st, :write_file, "Write file: ", dir_of(st) <> "/")
      b.modified -> elem(save_buffer(st, b), 1)
      true -> st
    end
  end

  # Compile the buffer's file to a PDF beside it. An error: the cursor goes
  # to it, the echo area says what it is, and typst's full report is in
  # the *typst* buffer. :preview opens the PDF as well (Firefox, on the
  # desktop).
  defp typst_compile(st, how) do
    b = buf(st)

    if b.path == nil do
      st
    else
      case Lepton.Typst.compile(Path.expand(b.path), st.ctx) do
        {:missing, why} ->
          msg(st, why, true)

        {:ok, pdf, output} ->
          st = typst_output(st, output)
          pdf_name = Lepton.Ctx.tildify(st.ctx, pdf)
          warn = if output =~ "warning:", do: " (with warnings: SPC b b *typst*)", else: ""

          case how do
            :preview ->
              quoted = "'" <> String.replace(pdf, "'", "'\\''") <> "'"
              {env, user} = {st.ctx.env, st.ctx.user}
              # (in the background: the editor doesn't wait for Firefox)
              spawn(fn -> Lepton.Shell.run_capture("open " <> quoted, cwd: Path.dirname(pdf), env: env, user: user) end)
              msg(st, "Compiled #{pdf_name}; opened it#{warn}")

            :save ->
              msg(st, "Wrote #{Lepton.Ctx.tildify(st.ctx, b.path)}, compiled #{Path.basename(pdf)}#{warn}")

            _ ->
              msg(st, "Compiled #{pdf_name}#{warn}")
          end

        {:error, output, where} ->
          st = typst_output(st, output)
          st =
            case where do
              {file, l, c} -> if Path.basename(file) == Path.basename(b.path), do: set_cursor(st, {max(l - 1, 0), max(c - 1, 0)}), else: st
              nil -> st
            end

          at = case where do
            {file, l, c} -> " (#{Path.basename(file)}:#{l}:#{c})"
            nil -> ""
          end

          msg(st, "Typst: " <> String.replace_prefix(Lepton.Typst.summary(output), "error: ", "") <> at <> "; SPC b b *typst* for all", true)
      end
    end
  end

  # typst's report, in a *typst* buffer (replaced each time).
  defp typst_output(st, output) do
    text = if String.trim(output) == "", do: "No errors or warnings.\n", else: output
    case Enum.find(Map.values(st.buffers), &(&1.name == "*typst*")) do
      nil -> add_buffer(st, Buffer.new("*typst*", text, kind: :help, mode: "Text", read_only: true))
      old -> put_buf(st, %{Buffer.set_lines(old, String.split(String.trim_trailing(text, "\n"), "\n")) | modified: false})
    end
  end

  defp msg(st, text, error \\ false)
  defp msg(st, nil, _), do: st
  defp msg(st, text, error), do: %{st | message: text, message_error: error, messages: Enum.take([text | st.messages], 200)}

  # -- saving ------------------------------------------------------------------------------

  defp save(st) do
    b = buf(st)

    cond do
      b.kind not in [:file, :scratch, :commit] -> st
      b.path == nil -> prompt(st, :write_file, "Write file: ", dir_of(st) <> "/")
      true ->
        {result, st} = save_buffer(st, b)
        # (A commit message's save says what was committed instead.)
        st = if result == :ok and b.kind != :commit, do: msg(st, "Wrote #{Lepton.Ctx.tildify(st.ctx, b.path)}"), else: st
        # A Typst file: its PDF too (as typst watch would), if Typst is there.
        if result == :ok and b.mode == "Typst" and st.vars["typst-compile-on-save"] and Lepton.Typst.installed?(), do: typst_compile(st, :save), else: st
    end
  end

  defp save_buffer(st, b) do
    # editing.el: (add-hook 'before-save-hook 'delete-trailing-whitespace)
    b = if st.vars["delete-trailing-whitespace-on-save"], do: Buffer.delete_trailing_whitespace(b), else: b

    allowed = if b.path, do: Lepton.Users.check_write(st.ctx, Path.expand(b.path)), else: :ok
    result = if allowed == :ok, do: Lepton.Users.own_new(st.ctx, Path.expand(b.path || "."), fn -> Buffer.save(b) end), else: {:error, "permission denied (to edit system files, run sudo le FILE)"}

    case result do
      {:ok, b} ->
        st = put_buf(st, b)
        st = if b.kind == :commit, do: Magit.commit_saved(st, b), else: st
        {:ok, if(b.id == win(st).buf, do: set_cursor(st, cursor(st)), else: st)}

      {:error, reason} ->
        {:error, msg(st, "Cannot save #{b.name}: #{reason}", true)}
    end
  end

  # A commit message buffer is done (committed, or not): back to the
  # repository's status, as magit does. The message stays in the echo area.
  defp close_commit(st) do
    b = buf(st)

    if b.kind == :commit do
      message = {st.message, st.message_error}
      st = kill_buffer(st, b.id)

      if st.quit do
        st
      else
        st = Magit.status_for(st, b.meta.repo_root)
        %{st | message: elem(message, 0), message_error: elem(message, 1)}
      end
    else
      st
    end
  end

  defp exit_insert_if_needed(%{mode: m} = st) when m in [:insert, :replace], do: exit_insert(st)
  defp exit_insert_if_needed(st), do: st

  # magit-save-repository-buffers: before git looks at the files, save
  # the modified buffers visiting files in the repository at `root`.
  defp save_repo_buffers(st, root) do
    root = Path.expand(root)

    Enum.reduce(st.order, {st, []}, fn id, {st, saved} ->
      b = st.buffers[id]

      if b.kind == :file and b.modified and b.path && String.starts_with?(Path.expand(b.path), root <> "/") do
        case save_buffer(st, b) do
          {:ok, st} -> {st, [b.name | saved]}
          {:error, st} -> {st, saved}
        end
      else
        {st, saved}
      end
    end)
  end

  defp revert(st) do
    b = buf(st)

    if b.path do
      nb = Buffer.from_file(b.path)
      st |> put_buf(%{nb | id: b.id}) |> set_cursor(cursor(st)) |> msg("Reverted #{b.name}")
    else
      st
    end
  end

  defp kill_buffer(st, id) do
    order = List.delete(st.order, id)

    if order == [] do
      %{st | quit: true}
    else
      next = if st.prev_buffer in order, do: st.prev_buffer, else: hd(order)
      windows = Map.new(st.windows, fn {wid, w} -> {wid, if(w.buf == id, do: %{w | buf: next, cursor: {0, 0}, top: 0}, else: w)} end)
      %{st | order: order, buffers: Map.delete(st.buffers, id), windows: windows, prev_buffer: nil}
      |> then(&set_cursor(&1, cursor(&1)))
    end
  end

  defp cycle_buffer(st, dir) do
    files = Enum.filter(st.order, &(st.buffers[&1].kind in [:file, :scratch, :dired]))
    files = if files == [], do: st.order, else: files
    idx = Enum.find_index(files, &(&1 == win(st).buf)) || 0
    show_buffer(st, Enum.at(files, rem(idx + dir + length(files), length(files))))
  end

  defp quit_window(st, force) do
    b = buf(st)

    cond do
      b.kind == :commit ->
        close_commit(st)

      b.kind in [:magit, :help, :log, :list, :dired] and map_size(st.windows) == 1 and length(st.order) > 1 ->
        kill_buffer(st, b.id)

      map_size(st.windows) > 1 ->
        delete_window(st, st.active)

      not force and b.modified and b.kind == :file ->
        msg(st, "No write since last change (add ! to override)", true)

      true ->
        %{st | quit: true}
    end
  end

  def special_buffer(st, name, kind, text, meta \\ %{}) do
    case Enum.find(Map.values(st.buffers), &(&1.name == name)) do
      nil ->
        b = Buffer.new(name, text, kind: kind, mode: "Special", meta: meta, read_only: true)
        st |> add_buffer(b) |> show_buffer(b.id)

      b ->
        nb = %{Buffer.new(name, text, kind: kind, mode: "Special", meta: meta, read_only: true) | id: b.id}
        st |> put_buf(nb) |> show_buffer(b.id)
    end
  end

  defp dired_buffer(dir) do
    entries =
      case File.ls(dir) do
        {:ok, names} -> Enum.sort_by(names, &{not File.dir?(Path.join(dir, &1)), &1})
        _ -> []
      end

    lines = ["  #{dir}:", "  ../"] ++ Enum.map(entries, fn n -> "  " <> n <> if(File.dir?(Path.join(dir, n)), do: "/", else: "") end)
    Buffer.new(Path.basename(dir) <> "/", Enum.join(lines, "\n"), kind: :dired, mode: "Dired", meta: %{dir: dir, cursor: {2, 2}}, path: dir, read_only: true)
  end

  # -- windows ---------------------------------------------------------------------------

  defp leaves({:leaf, id}), do: [id]
  defp leaves({:split, _, children}), do: Enum.flat_map(children, &leaves/1)

  defp split(st, dir) do
    w = win(st)
    id = (Map.keys(st.windows) |> Enum.max()) + 1
    nw = %{w | id: id, jumps: []}
    layout = replace_leaf(st.layout, st.active, {:split, dir, [{:leaf, st.active}, {:leaf, id}]})
    %{st | windows: Map.put(st.windows, id, nw), layout: flatten(layout), frame: [], maximized: nil}
    |> select_window(id)
  end

  defp replace_leaf({:leaf, id}, id, new), do: new
  defp replace_leaf({:leaf, _} = l, _, _), do: l
  defp replace_leaf({:split, d, ch}, id, new), do: {:split, d, Enum.map(ch, &replace_leaf(&1, id, new))}

  # Merge nested splits in the same direction.
  defp flatten({:split, d, children}) do
    children =
      Enum.flat_map(children, fn
        {:split, ^d, inner} -> Enum.map(inner, &flatten/1)
        other -> [flatten(other)]
      end)

    case children do
      [one] -> one
      many -> {:split, d, many}
    end
  end

  defp flatten(leaf), do: leaf

  defp remove_leaf({:leaf, id}, id), do: nil
  defp remove_leaf({:leaf, _} = l, _), do: l

  defp remove_leaf({:split, d, ch}, id) do
    case ch |> Enum.map(&remove_leaf(&1, id)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      [one] -> one
      many -> {:split, d, many}
    end
  end

  defp delete_window(st, id) do
    if map_size(st.windows) == 1 do
      msg(st, "Attempt to delete minibuffer or sole ordinary window", true)
    else
      layout = remove_leaf(st.layout, id)
      next = layout |> leaves() |> hd()
      %{st | windows: Map.delete(st.windows, id), layout: layout, active: next, frame: [], maximized: nil}
      |> then(&set_cursor(&1, cursor(&1)))
    end
  end

  defp select_window(st, id) do
    %{st | active: id, last_window: st.active} |> then(&set_cursor(&1, cursor(&1)))
  end

  defp other_window(st) do
    ids = leaves(st.layout)
    idx = Enum.find_index(ids, &(&1 == st.active))
    select_window(st, Enum.at(ids, rem(idx + 1, length(ids))))
  end

  # Spacemacs tmux layer: move between editor windows, and beyond the
  # edge into the neighbouring multiplexer pane.
  defp window_move(st, dir) do
    rects = rects(st)
    {r, c, h, w} = rects[st.active]
    {cl, _} = cursor(st)
    row = r + min(cl - win(st).top, h - 1)

    candidates =
      for {id, {r2, c2, h2, w2}} <- rects, id != st.active, reduce: [] do
        acc ->
          ok =
            case dir do
              :left -> c2 + w2 <= c and row >= r2 and row < r2 + h2
              :right -> c2 >= c + w and row >= r2 and row < r2 + h2
              :up -> r2 + h2 <= r and c >= c2 - 1 and c < c2 + w2
              :down -> r2 >= r + h and c >= c2 - 1 and c < c2 + w2
            end

          if ok, do: [{id, abs(c2 - c) + abs(r2 - r)} | acc], else: acc
      end

    case Enum.min_by(candidates, &elem(&1, 1), fn -> nil end) do
      {id, _} -> select_window(st, id)
      nil -> tmux_navigate(st, dir)
    end
  end

  defp tmux_navigate(st, dir) do
    case Lepton.Mux.navigate_from(st.tty, dir) do
      :ok -> st
      _ -> st
    end
  end

  # -- visual state ------------------------------------------------------------------------

  defp visual_key(st, key) do
    cond do
      st.pending == [] and key =~ ~r/^[1-9]$/ ->
        %{st | count: key_count(st.count, key)}

      true ->
        seq = st.pending ++ [key]

        case Keymap.lookup(st.km.visual, seq) do
          {:action, action} ->
            count = st.count
            st = %{st | pending: [], count: nil}
            visual_action(st, action, count)

          :prefix ->
            %{st | pending: seq}

          :none ->
            st = %{st | pending: []}

            case Motion.parse(seq) do
              {:motion, m} -> st |> block_eol_for(m) |> move(m) |> Map.put(:count, nil)
              {:object, obj} ->
                case Motion.object(buf(st), cursor(st), obj) do
                  {:range, from, {tl, tc}, _} -> %{st | visual_start: from} |> set_cursor({tl, max(tc - 1, 0)})
                  :none -> st
                end

              :more -> %{st | pending: seq}
              _ -> st
            end
        end
    end
  end

  defp region(st) do
    {a, b} = order(st.visual_start, cursor(st))

    case st.mode do
      m when m in [:visual_line, :visual_block] -> {{elem(a, 0), 0}, {elem(b, 0), 0}, :linewise}
      _ -> {a, b, :inclusive}
    end
  end

  defp region_lines(st) do
    if st.mode in [:visual, :visual_line, :visual_block] do
      {{fl, _}, {tl, _}, _} = region(st)
      {fl, tl}
    else
      {0, Buffer.line_count(buf(st)) - 1}
    end
  end

  defp leave_visual(st), do: %{st | last_visual: {st.mode, st.visual_start, cursor(st)}, mode: :normal, visual_start: nil, block_eol: false}

  defp visual_action(%{mode: :visual_block} = st, action, count) do
    case action do
      a when a in [:visual_delete, :visual_yank, :visual_change, :visual_upcase, :visual_downcase, :visual_toggle_case,
                   :visual_insert, :visual_append, :visual_paste, :visual_other_side, :replace_char, :visual_toggle_block] ->
        block_action(st, a)

      :visual_toggle_char -> %{st | mode: :visual}
      :visual_toggle_line -> %{st | mode: :visual_line}
      :normal_state -> leave_visual(st) |> then(&set_cursor(&1, cursor(&1)))

      # The rest act on the block's lines (>, <, J, :, sorting, commenting).
      a ->
        st = visual_action(%{st | mode: :visual_line}, a, count)
        if st.mode == :visual_line, do: %{st | mode: :visual_block}, else: st
    end
  end

  defp visual_action(st, action, count) do
    {from, to, kind} = region(st)

    case action do
      :normal_state -> leave_visual(st) |> then(&set_cursor(&1, cursor(&1)))
      :visual_toggle_block -> %{st | mode: :visual_block, block_eol: false}
      :visual_other_side -> %{st | visual_start: cursor(st)} |> set_cursor(st.visual_start)
      :visual_toggle_char -> if st.mode == :visual, do: leave_visual(st), else: %{st | mode: :visual}
      :visual_toggle_line -> if st.mode == :visual_line, do: leave_visual(st), else: %{st | mode: :visual_line}
      :visual_other_end -> %{st | visual_start: cursor(st)} |> set_cursor(st.visual_start)
      :visual_delete -> leave_visual(st) |> Map.put(:operator, :delete) |> apply_operator(from, to, kind)
      :visual_yank -> leave_visual(st) |> Map.put(:operator, :yank) |> apply_operator(from, to, kind)
      :visual_change -> leave_visual(st) |> Map.put(:operator, :change) |> apply_operator(from, to, kind)
      :visual_indent -> leave_visual(st) |> Map.put(:operator, :indent) |> apply_operator(from, to, :linewise)
      :visual_dedent -> leave_visual(st) |> Map.put(:operator, :dedent) |> apply_operator(from, to, :linewise)
      :visual_upcase -> visual_case(st, :upcase)
      :visual_downcase -> visual_case(st, :downcase)
      :visual_toggle_case -> visual_case(st, :toggle_case)
      :visual_join -> leave_visual(st) |> set_cursor(from) |> join(elem(to, 0) - elem(from, 0) + 1, true)

      :visual_paste ->
        reg = register_for(st)
        st = %{st | use_register: nil}
        st = leave_visual(st) |> Map.put(:operator, :delete) |> apply_operator(from, to, kind)
        # (a selection that reached the end of its line, or of the buffer: put after what's left)
        {fl, fc} = from
        b = buf(st)

        where =
          cond do
            kind == :linewise -> if fl >= Buffer.line_count(b), do: :after, else: :before
            fc > 0 and fc >= Buffer.line_length(b, fl) -> :after
            true -> :before
          end

        if reg, do: paste_register(st, where, 1, reg), else: st

      # ": the register for the next yank, delete or paste (staying in visual).
      :select_register -> %{st | awaiting: :select_register}

      :visual_insert -> leave_visual(st) |> set_cursor(from) |> enter_insert()
      :visual_append -> leave_visual(st) |> set_cursor({elem(to, 0), elem(to, 1) + 1}) |> enter_insert()
      a when a in [:sort_lines, :align_repeat, :comment_line, :delete_trailing_whitespace] -> do_action(st, a, count) |> then(&if(&1.mode in [:visual, :visual_line], do: leave_visual(&1), else: &1))
      :ex -> prompt(st, :ex, ":", "'<,'>")
      other -> do_action(leave_visual(st), other, count)
    end
  end

  # -- visual block -------------------------------------------------------------------------

  # `$` makes the block reach every line's end; a motion across lines keeps that.
  defp block_eol_for(%{mode: :visual_block} = st, m) do
    cond do
      m == "$" -> %{st | block_eol: true}
      m in ["j", "k", "<up>", "<down>", "G", "gg", "C-d", "C-u"] -> st
      true -> %{st | block_eol: false}
    end
  end

  defp block_eol_for(st, _m), do: st

  # The block: its lines, and its columns (display columns: tabs and wide
  # characters as they show), from the corners' characters.
  @doc false
  def block_columns(st), do: block(st)

  defp block(st) do
    b = buf(st)
    {sl, _} = st.visual_start
    {cl, _} = cursor(st)
    span = fn {l, c} -> line = Buffer.line(b, l); d = display_col(line, c); {d, d + block_char_width(line, c)} end
    {s0, s1} = span.(st.visual_start)
    {c0, c1} = span.(cursor(st))
    # On a line too short for it, the cursor keeps the column it was going
    # to (as Vim): the block stays as wide.
    want = win(st).want_col
    {c0, c1} = if want > elem(cursor(st), 1), do: {max(c0, want), max(c0, want) + 1}, else: {c0, c1}
    %{fl: min(sl, cl), tl: max(sl, cl), left: min(s0, c0), right: max(s1, c1), eol: st.block_eol}
  end

  defp block_char_width(line, c) do
    case String.at(line, c) do
      nil -> 1
      "\t" -> 8 - rem(display_col(line, c), 8)
      g -> max(Lepton.Width.grapheme(g), 1)
    end
  end

  # The characters of `line` in the block: {from, to} (to exclusive); none
  # for a line that ends before the block starts.
  defp block_range(line, blk) do
    len = String.length(line)

    if display_col(line, len) <= blk.left do
      {len, len}
    else
      to = if blk.eol, do: len, else: min(column_at(line, blk.right - 1) + 1, len)
      {column_at(line, blk.left), to}
    end
  end

  # `line` with `text` put at display column `col` (spaces up to it if the line is shorter).
  defp insert_at_col(line, col, text) do
    width = display_col(line, String.length(line))

    if width < col,
      do: line <> String.duplicate(" ", col - width) <> text,
      else: String.slice(line, 0, column_at(line, col)) <> text <> String.slice(line, column_at(line, col)..-1//1)
  end

  # Each line of the block through `fun.(line, {from, to})`, which returns {new_line, taken}.
  defp map_block(st, blk, fun) do
    # (the snapshot first: the buffer carries its undo history)
    st = snapshot(st)
    b = buf(st)
    {lines, taken} = for l <- blk.fl..blk.tl, reduce: {[], []} do
      {lines, taken} ->
        line = Buffer.line(b, l)
        {new, t} = fun.(line, block_range(line, blk))
        {[new | lines], [t | taken]}
    end

    {put_buf(st, Buffer.replace_lines(b, blk.fl, blk.tl, Enum.reverse(lines))), Enum.reverse(taken)}
  end

  defp block_top_left(st, blk), do: set_cursor(st, {blk.fl, elem(block_range(Buffer.line(buf(st), blk.fl), blk), 0)})

  defp block_action(st, action) do
    blk = block(st)

    case action do
      :visual_toggle_block -> leave_visual(st)

      # O: the other corner on the same line.
      :visual_other_side ->
        {sl, sc} = st.visual_start
        {cl, cc} = cursor(st)
        %{st | visual_start: {sl, cc}} |> set_cursor({cl, sc})

      :visual_yank ->
        rows = for l <- blk.fl..blk.tl, line = Buffer.line(buf(st), l), {a, z} = block_range(line, blk), do: String.slice(line, a, z - a)
        st |> leave_visual() |> set_register({:block, rows}, :yank) |> block_top_left(blk)

      :visual_delete ->
        {st, rows} = map_block(leave_visual(st), blk, fn line, {a, z} -> {String.slice(line, 0, a) <> String.slice(line, z..-1//1), String.slice(line, a, z - a)} end)
        st |> set_register({:block, rows}) |> block_top_left(blk)

      op when op in [:visual_upcase, :visual_downcase, :visual_toggle_case] ->
        how = %{visual_upcase: :upcase, visual_downcase: :downcase, visual_toggle_case: :toggle_case}[op]
        {st, _} = map_block(leave_visual(st), blk, fn line, {a, z} -> {String.slice(line, 0, a) <> recase(String.slice(line, a, z - a), how) <> String.slice(line, z..-1//1), nil} end)
        block_top_left(st, blk)

      # r: the next key is the character every one of the block's becomes.
      :replace_char ->
        %{leave_visual(st) | awaiting: {:block_replace, blk}}

      # I and c type on the first line, at the block's left; A after its
      # right (or each line's end, after $). Escape puts what was typed on
      # the block's other lines too (I and c: those that reach the block).
      :visual_insert ->
        block_insert(leave_visual(st), blk, :insert)

      :visual_change ->
        {st, rows} = map_block(leave_visual(st), blk, fn line, {a, z} -> {String.slice(line, 0, a) <> String.slice(line, z..-1//1), String.slice(line, a, z - a)} end)
        st |> set_register({:block, rows}) |> block_insert(blk, :change)

      :visual_append ->
        block_insert(leave_visual(st), blk, :append)

      # p: the block replaced by what the register holds.
      :visual_paste ->
        reg = register_for(st)
        {st, _} = map_block(leave_visual(%{st | use_register: nil}), blk, fn line, {a, z} -> {String.slice(line, 0, a) <> String.slice(line, z..-1//1), nil} end)
        st = block_top_left(st, blk)
        if reg, do: paste_register(st, :before, 1, reg), else: st
    end
  end

  defp block_insert(st, blk, how) do
    # (c took its snapshot when it deleted the block)
    st = if how == :change, do: st, else: snapshot(st)
    b = buf(st)
    first = Buffer.line(b, blk.fl)
    width = fn line -> display_col(line, String.length(line)) end

    {first, col} =
      case how do
        :append when blk.eol -> {first, width.(first)}
        :append -> {if(width.(first) < blk.right, do: first <> String.duplicate(" ", blk.right - width.(first)), else: first), blk.right}
        _ -> {first, blk.left}
      end

    others = for l <- (blk.fl + 1)..blk.tl//1, how == :append or width.(Buffer.line(b, l)) >= blk.left, do: l
    st = put_buf(st, Buffer.replace_lines(b, blk.fl, blk.fl, [first]))
    start = {blk.fl, column_at(first, col)}
    st = set_cursor(%{st | mode: :insert}, start)
    %{enter_insert(st, false) | block_insert: %{start: start, lines: others, col: col, eol: how == :append and blk.eol, count: Buffer.line_count(b)}}
  end

  # Escape after I, A or c on a block: what was typed on the first line goes
  # on the others (if it stayed on that one line).
  defp finish_block_insert(%{block_insert: nil} = st), do: st

  defp finish_block_insert(%{block_insert: bi} = st) do
    st = %{st | block_insert: nil}
    {sl, sc} = bi.start
    {l, c} = cursor(st)
    b = buf(st)

    if l == sl and c > sc and Buffer.line_count(b) == bi.count do
      text = String.slice(Buffer.line(b, sl), sc, c - sc)

      Enum.reduce(bi.lines, st, fn n, st ->
        b = buf(st)
        line = Buffer.line(b, n)
        new = if bi.eol, do: line <> text, else: insert_at_col(line, bi.col, text)
        put_buf(st, Buffer.replace_lines(b, n, n, [new]))
      end)
    else
      st
    end
  end

  defp visual_case(st, op) do
    {from, to, kind} = region(st)
    leave_visual(st) |> Map.put(:operator, op) |> apply_operator(from, to, kind)
  end

  # -- insert state -------------------------------------------------------------------------

  defp enter_insert(st, snapshot? \\ true) do
    st = if snapshot?, do: snapshot(st), else: st
    %{st | mode: if(st.mode == :replace, do: :replace, else: :insert), insert_snapshot: true}
  end

  defp insert_key(st, key) do
    escape = st.vars["evil-escape-key-sequence"] || "jk"
    [e1, e2] = String.graphemes(escape) |> then(&if(length(&1) == 2, do: &1, else: ["j", "k"]))

    cond do
      # evil-escape: "jk" typed quickly leaves insert state
      st.jk_pending && key == e2 ->
        {l, c} = cursor(st)
        {b, _} = Buffer.delete_range(buf(st), {l, c - 1}, {l, c})
        st |> put_buf(b) |> set_cursor({l, c - 1}, eol: true) |> Map.put(:jk_pending, nil) |> exit_insert()

      true ->
        st = %{st | jk_pending: nil}
        insert_dispatch(st, key, e1)
    end
  end

  defp insert_dispatch(st, key, e1) do
    seq = st.pending ++ [key]
    table = if st.completion, do: Map.merge(st.km.insert, st.km.completion), else: st.km.insert
    table = if buf(st).kind == :commit, do: Map.merge(table, @commit_insert), else: table

    case Keymap.lookup(table, seq) do
      {:action, action} -> insert_action(%{st | pending: []}, action) |> update_completion(action)
      :prefix -> %{st | pending: seq}
      :none ->
        st = %{st | pending: []}

        case Keys.text(key) do
          nil -> st
          text ->
            st = self_insert(st, text)
            st = if text == e1 and not st.replaying, do: %{st | jk_pending: true}, else: st
            update_completion(st, :self_insert)
        end
    end
  end

  defp self_insert(st, text) do
    {l, c} = cursor(st)
    b = buf(st)

    b =
      if st.mode == :replace and c < Buffer.line_length(b, l) do
        {b, _} = Buffer.delete_range(b, {l, c}, {l, c + 1})
        b
      else
        b
      end

    {b, pos} = Buffer.insert(b, {l, c}, text)
    st |> put_buf(b) |> set_cursor(pos)
  end

  defp exit_insert(st) do
    st = finish_block_insert(st)
    {l, c} = cursor(st)
    st = %{st | mode: :normal, completion: nil, insert_snapshot: false}
    st = set_cursor(st, {l, max(c - 1, 0)})
    if st.recording, do: %{st | last_change: st.recording, recording: nil}, else: st
  end

  defp insert_action(st, action) do
    {l, c} = cursor(st)
    b = buf(st)

    case action do
      :normal_state -> exit_insert(st)

      :newline ->
        line = Buffer.line(b, l)
        indent = leading(line)
        {b, _} = Buffer.insert(b, {l, c}, "\n" <> indent)
        st |> put_buf(b) |> set_cursor({l + 1, String.length(indent)})

      :backspace ->
        cond do
          c > 0 ->
            {b, _} = Buffer.delete_range(b, {l, c - 1}, {l, c})
            st |> put_buf(b) |> set_cursor({l, c - 1})

          l > 0 ->
            prev = Buffer.line_length(b, l - 1)
            {b, _} = Buffer.delete_range(b, {l - 1, prev}, {l, 0})
            st |> put_buf(b) |> set_cursor({l - 1, prev})

          true ->
            st
        end

      :delete_forward ->
        len = Buffer.line_length(b, l)
        cond do
          c < len -> {b, _} = Buffer.delete_range(b, {l, c}, {l, c + 1}); put_buf(st, b)
          l + 1 < Buffer.line_count(b) -> {b, _} = Buffer.delete_range(b, {l, c}, {l + 1, 0}); put_buf(st, b)
          true -> st
        end

      :delete_backward_word ->
        start = word_start_in_line(Buffer.line(b, l), c)
        {b, _} = Buffer.delete_range(b, {l, start}, {l, c})
        st |> put_buf(b) |> set_cursor({l, start})

      :kill_eol ->
        {b, _} = Buffer.delete_range(b, {l, c}, {l, Buffer.line_length(b, l)})
        put_buf(st, b)

      # M-t: the words before and after the cursor change places (Emacs's transpose-words).
      :transpose_words ->
        case Lepton.Transpose.words(Buffer.line(b, l), c) do
          {line, c2} -> st |> put_buf(Buffer.replace_lines(b, l, l, [line])) |> set_cursor({l, c2})
          :none -> st
        end

      :indent -> self_insert(st, Buffer.indent_unit(b))
      :indent_line -> st |> put_buf(Buffer.replace_lines(b, l, l, [Buffer.indent_unit(b) <> Buffer.line(b, l)])) |> set_cursor({l, c + String.length(Buffer.indent_unit(b))})
      :tab_command -> tab_command(st)
      :snippet_expand -> elem(Lepton.Editor.Snippets.expand(st, buf(st), cursor(st)), 0) |> then(fn {b, pos} -> st |> put_buf(b) |> set_cursor(pos) end)
      :left -> set_cursor(st, {l, c - 1})
      :right -> set_cursor(st, {l, c + 1})
      :next_line -> set_cursor(st, {l + 1, c})
      :previous_line -> set_cursor(st, {l - 1, c})
      :bol -> set_cursor(st, {l, 0})
      :eol -> set_cursor(st, {l, Buffer.line_length(b, l)})
      :save -> save(st)
      :normal_one -> st |> exit_insert() |> then(&set_cursor(&1, {l, c}))
      :quoted_insert -> %{st | awaiting: :quoted_insert}

      :insert_eex_statement -> st |> self_insert("<%  %>") |> then(&set_cursor(&1, {l, c + 3}))
      :insert_eex_expression -> st |> self_insert("<%=  %>") |> then(&set_cursor(&1, {l, c + 4}))
      :completion_next -> completion_move(st, 1)
      :completion_previous -> completion_move(st, -1)
      :completion_accept -> completion_accept(st)
      :completion_accept_or_newline -> if st.completion && st.completion.selected >= 0, do: completion_accept(st), else: insert_action(%{st | completion: nil}, :newline)
      :completion_abort -> %{st | completion: nil} |> exit_insert()
      other -> do_action(st, other, nil)
    end
  end

  defp word_start_in_line(line, c) do
    before = String.slice(line, 0, c)
    trimmed = String.trim_trailing(before)
    String.length(Regex.replace(~r/[\p{L}\p{N}_]+$|[^\p{L}\p{N}_\s]+$/u, trimmed, ""))
  end

  # my-tab-command: (indent-for-tab-command) then (yas-expand)
  defp tab_command(st) do
    {l, c} = cursor(st)
    b = buf(st)
    line = Buffer.line(b, l)
    {b2, pos} = Lepton.Editor.Snippets.expand(st, b, {l, c}) |> elem(0)

    if b2 != b do
      st |> put_buf(b2) |> set_cursor(pos)
    else
      if String.trim(String.slice(line, 0, c)) == "", do: self_insert(st, Buffer.indent_unit(b)), else: st
    end
  end

  # company-mode-lite: words from the buffer completing the word before point.
  defp update_completion(st, action) when action in [:self_insert, :backspace, :delete_backward_word] do
    {l, c} = cursor(st)
    prefix = Regex.run(~r/[\p{L}\p{N}_]+$/u, String.slice(Buffer.line(buf(st), l), 0, c)) |> then(&(&1 && hd(&1)))

    if prefix && String.length(prefix) >= 2 do
      words =
        buf(st)
        |> completion_text(l)
        |> completion_words(prefix)
        |> Enum.filter(&(&1 != prefix))
        |> Enum.frequencies()
        |> Enum.sort_by(fn {w, n} -> {-n, w} end)
        |> Enum.take(8)
        |> Enum.map(&elem(&1, 0))

      if words == [], do: %{st | completion: nil}, else: %{st | completion: %{prefix: prefix, items: words, selected: -1}}
    else
      %{st | completion: nil}
    end
  end

  defp update_completion(st, action) when action in [:completion_next, :completion_previous], do: st

  defp update_completion(st, _), do: %{st | completion: nil}

  # The text completion looks in: the whole buffer, or in a big one, the
  # lines around the cursor (about 2 MB of them), as dabbrev looks nearest
  # first. (One search of one binary: a regex per line, every key, made
  # typing in a 1 MB file take a tenth of a second a character.)
  @completion_bytes 2_000_000
  defp completion_text(b, l) do
    # up to half the bytes above the cursor's line, and the rest below it
    above = gather(b, l - 1, -1, div(@completion_bytes, 2), [])
    below = gather(b, l, 1, @completion_bytes - :erlang.iolist_size(above), []) |> Enum.reverse()
    IO.iodata_to_binary([above | below])
  end

  defp gather(b, i, dir, left, acc) do
    if left <= 0 or i < 0 or i >= Buffer.line_count(b) do
      acc
    else
      line = Buffer.line(b, i)
      gather(b, i + dir, dir, left - byte_size(line) - 1, [line, "\n" | acc])
    end
  end

  # Words of three letters or more starting with `prefix` (at a word's start).
  @doc false
  def completion_words(text, prefix) do
    re = Regex.compile!("(?<![\\p{L}\\p{N}_])" <> Regex.escape(prefix) <> "[\\p{L}\\p{N}_]*", "u")
    for [w] <- Regex.scan(re, text), String.length(w) >= 3, do: w
  end

  defp completion_move(%{completion: nil} = st, dir), do: insert_action(st, if(dir > 0, do: :next_line, else: :previous_line))

  defp completion_move(st, dir) do
    n = length(st.completion.items)
    %{st | completion: %{st.completion | selected: rem(st.completion.selected + dir + n, n)}}
  end

  defp completion_accept(%{completion: nil} = st), do: insert_action(st, :indent)

  defp completion_accept(st) do
    %{prefix: prefix, items: items, selected: sel} = st.completion
    word = Enum.at(items, max(sel, 0))
    self_insert(%{st | completion: nil}, String.slice(word, String.length(prefix)..-1//1))
  end

  # -- special (evilified) buffers: magit, dired, help -------------------------------------

  defp special_key(st, key) do
    seq = st.pending ++ [key]
    b = buf(st)
    table = if b.kind == :magit, do: Map.merge(st.km.special, st.km.magit), else: st.km.special

    case Keymap.lookup(table, seq) do
      {:action, action} -> special_action(%{st | pending: []}, action)
      :prefix -> %{st | pending: seq}
      :none ->
        st = %{st | pending: []}

        case Motion.parse(seq) do
          {:motion, m} -> move(st, m)
          :more -> %{st | pending: seq}
          _ -> st
        end
    end
  end

  defp special_action(st, action) do
    b = buf(st)

    case action do
      :next_line -> move(st, "j")
      :previous_line -> move(st, "k")
      :goto_first -> move(st, "gg")
      :goto_last -> move(st, "G")
      :quit_special -> quit_window(st, true)
      :dired_up when b.kind == :dired -> visit(st, Path.dirname(b.meta.dir))
      :special_open when b.kind == :dired -> dired_open(st)
      :special_open when b.kind == :list -> goto_grep_result(st)
      :special_refresh when b.kind == :dired -> special_buffer(st, b.name, :dired, Buffer.text(dired_buffer(b.meta.dir)), b.meta)
      a when b.kind in [:magit, :log] -> Magit.action(st, a)
      :special_open when b.kind == :help -> st
      other -> do_action(st, other, nil)
    end
  end

  defp dired_open(st) do
    b = buf(st)
    {l, _} = cursor(st)
    name = Buffer.line(b, l) |> String.trim() |> String.trim_trailing("/")

    cond do
      l == 0 -> st
      name == ".." -> visit(st, Path.dirname(b.meta.dir))
      true -> visit(st, Path.join(b.meta.dir, name))
    end
  end

  # -- minibuffer -------------------------------------------------------------------------------

  defp prompt(st, kind, label, initial) do
    %{st | minibuffer: %{kind: kind, prompt: label, text: initial, pos: String.length(initial), candidates: [], selected: 0}, pending: []}
  end

  defp minibuffer_key(st, key) do
    mb = st.minibuffer

    case Keymap.lookup(st.km.minibuffer, st.pending ++ [key]) do
      {:action, action} -> minibuffer_action(%{st | pending: []}, action)
      :prefix -> %{st | pending: st.pending ++ [key]}
      :none ->
        st = %{st | pending: []}

        case Keys.text(key) do
          nil -> st
          t ->
            {a, b} = String.split_at(mb.text, mb.pos)
            mb = %{mb | text: a <> t <> b, pos: mb.pos + String.length(t), selected: 0}
            st = %{st | minibuffer: mb}

            if mb.kind in [:confirm_quit, :confirm_delete, :describe_key] do
              minibuffer_action(st, :mb_accept)
            else
              refresh_candidates(st) |> incremental_search()
            end
        end
    end
  end

  defp minibuffer_action(st, action) do
    mb = st.minibuffer

    case action do
      :mb_cancel -> %{st | minibuffer: nil} |> msg("Quit")
      :mb_accept -> accept(%{st | minibuffer: nil}, mb)
      :mb_next -> %{st | minibuffer: %{mb | selected: min(mb.selected + 1, max(length(mb.candidates) - 1, 0))}}
      :mb_previous -> %{st | minibuffer: %{mb | selected: max(mb.selected - 1, 0)}}
      :mb_kill -> %{st | minibuffer: %{mb | text: "", pos: 0}} |> refresh_candidates()
      :mb_complete -> complete_minibuffer(st)

      :backspace ->
        if mb.pos == 0 and mb.text == "" do
          %{st | minibuffer: nil}
        else
          {a, b} = String.split_at(mb.text, mb.pos)
          %{st | minibuffer: %{mb | text: String.slice(a, 0..-2//1) <> b, pos: max(mb.pos - 1, 0)}} |> refresh_candidates()
        end

      :delete_backward_word ->
        {a, b} = String.split_at(mb.text, mb.pos)
        kept = Regex.replace(~r/[^\/\s]*[\/\s]?$/, a, "", global: false) |> then(&if(&1 == a, do: String.slice(a, 0..-2//1), else: &1))
        %{st | minibuffer: %{mb | text: kept <> b, pos: String.length(kept)}} |> refresh_candidates()

      :left -> %{st | minibuffer: %{mb | pos: max(mb.pos - 1, 0)}}
      :right -> %{st | minibuffer: %{mb | pos: min(mb.pos + 1, String.length(mb.text))}}
      :bol -> %{st | minibuffer: %{mb | pos: 0}}
      :eol -> %{st | minibuffer: %{mb | pos: String.length(mb.text)}}
      :kill_eol -> %{st | minibuffer: %{mb | text: String.slice(mb.text, 0, mb.pos)}}
      _ -> st
    end
  end

  defp complete_minibuffer(st) do
    mb = st.minibuffer

    case {mb.kind, Enum.at(mb.candidates, mb.selected)} do
      {k, cand} when k in [:find_file, :write_file] and cand != nil ->
        dir = if String.ends_with?(mb.text, "/"), do: mb.text, else: Path.dirname(mb.text) <> "/"
        text = dir <> cand
        %{st | minibuffer: %{mb | text: text, pos: String.length(text), selected: 0}} |> refresh_candidates()

      {_, cand} when cand != nil ->
        %{st | minibuffer: %{mb | text: cand, pos: String.length(cand)}}

      _ ->
        st
    end
  end

  def refresh_candidates(%{minibuffer: nil} = st), do: st

  def refresh_candidates(st) do
    mb = st.minibuffer
    q = mb.text

    candidates =
      case mb.kind do
        k when k in [:find_file, :write_file] ->
          path = Lepton.Ctx.path(st.ctx, if(q == "", do: ".", else: q))
          {dir, base} = if String.ends_with?(q, "/"), do: {path, ""}, else: {Path.dirname(path), Path.basename(q)}

          case File.ls(dir) do
            {:ok, names} ->
              names
              |> Enum.filter(&fuzzy?(&1, base))
              |> Enum.sort_by(&{not String.starts_with?(&1, base), String.starts_with?(&1, "."), &1})
              |> Enum.map(&(if File.dir?(Path.join(dir, &1)), do: &1 <> "/", else: &1))
              |> Enum.take(200)

            _ ->
              []
          end

        :switch_buffer ->
          st.order |> Enum.map(&st.buffers[&1].name) |> Enum.filter(&fuzzy?(&1, q))

        :project_file ->
          project_files(st) |> Enum.filter(&fuzzy?(&1, q)) |> Enum.take(200)

        :mx ->
          mx_commands(st) |> Enum.filter(&fuzzy?(&1, q))

        :swoop ->
          if q == "" do
            []
          else
            re = Regex.compile(q, "u") |> then(fn {:ok, r} -> r; _ -> ~r/(?!)/ end)

            buf(st) |> Buffer.lines() |> Enum.with_index(1)
            |> Enum.filter(fn {line, _} -> Regex.match?(re, line) end)
            |> Enum.map(fn {line, n} -> "#{n}: #{line}" end)
            |> Enum.take(200)
          end

        _ ->
          []
      end

    %{st | minibuffer: %{mb | candidates: candidates}}
  end

  # helm's default matching: space separated patterns, all must match.
  defp fuzzy?(_s, ""), do: true
  defp fuzzy?(s, q), do: q |> String.split() |> Enum.all?(&String.contains?(String.downcase(s), String.downcase(&1)))

  # The project's files, relative to its root: in a git repository the
  # worktree's, as git sees them (what .gitignore and the excludes leave,
  # dotfiles such as .formatter.exs included; never .git); elsewhere every
  # file but hidden ones. _build/ and deps/ are left out either way.
  # (SPC p f, SPC /, SPC p R)
  defp project_files(st) do
    case Lepton.Git.root(dir_of(st)) do
      nil ->
        root = dir_of(st)

        Path.wildcard(Path.join(root, "**/*"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.reject(&build_dir?/1)

      root ->
        root
        |> Lepton.Git.Repo.open()
        |> Lepton.Git.worktree_files()
        |> Enum.reject(&build_dir?/1)
        |> Enum.filter(&File.regular?(Path.join(root, &1)))
    end
  end

  defp build_dir?(rel), do: Enum.any?(Path.split(rel), &(&1 in ["_build", "deps", ".git"]))

  defp mx_commands(st) do
    leader = st.km.normal |> Map.values() |> Enum.filter(&is_atom/1) |> Enum.map(&Keymap.action_label/1)
    (Keymap.command_names() ++ leader ++ Map.keys(st.emacs.aliases) ++ st.emacs.functions)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Incremental search (/ and ?) moves the cursor as you type.
  defp incremental_search(%{minibuffer: %{kind: {:search, dir}, text: q}} = st) when q != "" do
    case Regex.compile(q, search_flags(st)) do
      {:ok, re} ->
        origin = Map.get(st.minibuffer, :origin) || cursor(st)
        st = put_in(st.minibuffer[:origin], origin)
        {pos, _} = Motion.search(buf(st), origin, {re, dir}, 1, false)
        set_cursor(st, pos, reveal: true)

      _ ->
        st
    end
  end

  defp incremental_search(st), do: st

  defp search_flags(st), do: if(st.vars["case-fold-search"] in [true, "t"], do: "iu", else: "u")

  defp accept(st, %{kind: kind, text: text} = mb) do
    selected = Enum.at(mb.candidates, mb.selected)

    case kind do
      :ex -> Lepton.Editor.Ex.run(st, text)

      {:search, dir} ->
        case Regex.compile(text, search_flags(st)) do
          {:ok, re} -> %{st | search: {re, dir}} |> push_jump() |> msg((if dir > 0, do: "/", else: "?") <> text)
          {:error, _} -> msg(st, "Invalid regexp: #{text}", true)
        end

      :find_file ->
        target =
          cond do
            selected && not String.ends_with?(text, selected) and mb.candidates != [] ->
              dir = if String.ends_with?(text, "/"), do: text, else: Path.dirname(text) <> "/"
              dir <> selected

            true ->
              text
          end

        visit(st, Lepton.Ctx.path(st.ctx, String.trim_trailing(target, "/")))

      :write_file ->
        path = Lepton.Ctx.path(st.ctx, text)
        b = %{buf(st) | path: path, name: Path.basename(path), mode: Buffer.mode_for(path), kind: :file}
        st |> put_buf(b) |> save()

      :switch_buffer ->
        name = selected || text

        case Enum.find(Map.values(st.buffers), &(&1.name == name)) do
          nil -> st |> add_buffer(Buffer.new(name, "")) |> then(&show_buffer(&1, List.last(&1.order)))
          b -> show_buffer(st, b.id)
        end

      :project_file ->
        root = Lepton.Git.root(dir_of(st)) || dir_of(st)
        visit(st, Path.join(root, selected || text))

      :mx -> run_mx(st, selected || text)

      :swoop ->
        case selected && Integer.parse(selected) do
          {n, _} -> st |> push_jump() |> set_cursor({n - 1, 0}) |> then(&set_cursor(&1, {n - 1, Motion.first_non_blank(buf(&1), n - 1)}))
          _ -> st
        end

      :grep -> grep_project(st, text)
      {:replace_dir, how} ->
        dir = Lepton.Ctx.path(st.ctx, Path.expand(text, dir_of(st)))

        if File.dir?(dir),
          do: prompt(st, {:replace_from, how, {:dir, dir}}, "Replace #{if how == :regexp, do: "regexp ", else: ""}in #{dir}: ", ""),
          else: msg(st, "Not a directory: #{dir}", true)

      {:replace_from, _, _} when text == "" -> st
      {:replace_from, how, scope} -> prompt(st, {:replace_to, how, text, scope}, "Replace #{if how == :regexp, do: "regexp ", else: ""}\"#{text}\" with: ", "")
      {:replace_to, how, from, scope} -> start_project_replace(st, how, from, text, scope)

      {:align, {fl, tl}} -> align(st, fl, tl, text)

      :rename_file ->
        b = buf(st)
        new = Lepton.Ctx.path(st.ctx, text)

        case b.path && File.rename(b.path, new) do
          :ok -> put_buf(st, %{b | path: new, name: Path.basename(new)}) |> msg("Renamed to #{text}")
          _ -> msg(st, "Rename failed", true)
        end

      :confirm_delete ->
        if text == "y" and buf(st).path, do: (File.rm(buf(st).path); kill_buffer(st, buf(st).id) |> msg("Deleted")), else: st

      :confirm_quit -> if text == "y", do: %{st | quit: true}, else: st

      :describe_key ->
        keys = Keys.parse(text)
        action = case Keymap.lookup(st.km.normal, keys) do
          {:action, a} -> Keymap.action_label(a)
          _ -> "undefined"
        end
        msg(st, "#{text} runs #{action}")

      {:magit, fun} -> fun.(st, text)
      _ -> st
    end
  end

  defp run_mx(st, name) do
    name = Map.get(st.emacs.aliases, name, name)

    action =
      case Keymap.translate(name) do
        :unsupported -> name |> String.replace("-", "_") |> then(&(try do String.to_existing_atom(&1) rescue _ -> nil end))
        a -> a
      end

    if action, do: do_action(st, action, nil), else: msg(st, "[No match] #{name}", true)
  end

  # align-repeat from editing.el:
  #   (align-regexp start end (concat "\\(\\s-*\\)" regexp) 1 1 t)
  # i.e. justify the whitespace before every occurrence of REGEXP so the
  # occurrences line up, keeping at least one space.
  def align_lines(lines, re) do
    rows = Enum.map(lines, &Regex.split(re, &1, include_captures: true))
    start = Enum.map(rows, fn [first | rest] -> {first, rest} end)
    do_align(start)
  end

  defp do_align(rows) do
    if Enum.all?(rows, fn {_, rest} -> rest == [] end) do
      Enum.map(rows, &elem(&1, 0))
    else
      width =
        rows
        |> Enum.filter(fn {_, rest} -> rest != [] end)
        |> Enum.map(fn {built, _} -> built |> String.trim_trailing() |> String.length() end)
        |> Enum.max()

      rows
      |> Enum.map(fn
        {built, [sep, seg | rest]} -> {String.pad_trailing(String.trim_trailing(built), width) <> " " <> sep <> seg, rest}
        {built, [sep]} -> {String.pad_trailing(String.trim_trailing(built), width) <> " " <> sep, []}
        done -> done
      end)
      |> do_align()
    end
  end

  defp align(st, fl, tl, regexp) do
    case Regex.compile(regexp, "u") do
      {:ok, re} ->
        st = snapshot(st)
        b = buf(st)
        new = align_lines(Buffer.get_lines(b, fl, tl), re)
        st |> put_buf(Buffer.replace_lines(b, fl, tl, new)) |> msg("Aligned #{tl - fl + 1} lines on /#{regexp}/")

      _ ->
        msg(st, "Invalid regexp", true)
    end
  end

  defp grep_project(st, pattern) do
    root = Lepton.Git.root(dir_of(st)) || dir_of(st)

    results =
      case Regex.compile(pattern, search_flags(st)) do
        {:ok, re} ->
          for file <- project_files(st),
              {:ok, text} <- [File.read(Path.join(root, file))],
              String.valid?(text),
              {line, n} <- Enum.with_index(String.split(text, "\n"), 1),
              Regex.match?(re, line) do
            "#{file}:#{n}: #{String.trim(line)}"
          end
          |> Enum.take(500)

        _ ->
          []
      end

    special_buffer(st, "*grep*", :list, Enum.join(["Search \"#{pattern}\" in #{root}", "" | results], "\n"), %{root: root, cursor: {2, 0}})
  end

  # -- project replace (SPC p R, SPC p %) ---------------------------------------------------------

  # Every file in the project that has a match (an open buffer's text, else
  # the file's), visited in turn; each match asks: y replaces it, n skips it,
  # ! replaces it and all the rest, . replaces it and stops, q stops.
  # Changed buffers are left unsaved (:wa or SPC f S saves them all).
  defp start_project_replace(st, how, from, to, scope) do
    flags = if how == :regexp, do: search_flags(st), else: "u"

    case Regex.compile(if(how == :regexp, do: from, else: Regex.escape(from)), flags) do
      {:ok, re} ->
        {root, paths} =
          case scope do
            :project ->
              root = Lepton.Git.root(dir_of(st)) || dir_of(st)
              {root, Enum.map(project_files(st), &Path.join(root, &1))}

            {:dir, dir} ->
              {dir, directory_files(dir)}
          end

        files =
          for path <- paths,
              text = project_text(st, path),
              text != nil and Regex.match?(re, text),
              do: path

        if files == [] do
          msg(st, "No match for \"#{from}\" in #{root}")
        else
          q = %{re: re, to: if(how == :regexp, do: to, else: String.replace(to, "\\", "\\\\")), files: files, replaced: 0, changed: MapSet.new(), at: nil}
          next_match(%{st | query: q}, :next_file)
        end

      {:error, {reason, _}} ->
        msg(st, "Invalid regexp: #{reason}", true)
    end
  end

  # Every file under `dir`, hidden and ignored ones too; never inside .git.
  defp directory_files(dir) do
    Path.wildcard(Path.join(dir, "**/*"), match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, dir))))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp project_text(st, path) do
    case buffer_for_path(st, path) do
      %{} = b -> Buffer.text(b)
      nil -> with {:ok, t} <- File.read(path), true <- String.valid?(t), do: t, else: (_ -> nil)
    end
  end

  # The next match from the cursor, in this file or the next ones.
  defp next_match(%{query: q} = st, :next_file) do
    case q.files do
      [] -> finish_query(st)
      [path | rest] -> st |> Map.put(:query, %{q | files: rest}) |> visit(path) |> set_cursor({0, 0}) |> next_match({0, 0})
    end
  end

  defp next_match(%{query: q} = st, from) do
    case find_match(buf(st), q.re, from) do
      nil -> next_match(st, :next_file)
      {l, a, z} -> %{st | query: %{q | at: {l, a, z}}} |> set_cursor({l, a}) |> query_prompt()
    end
  end

  defp query_prompt(st), do: msg(st, "Replace with \"#{st.query.to}\"? (y, n, ! all, . this and stop, q quit)")

  # The first match at or after {line, column}: {line, from, to} in characters.
  defp find_match(b, re, {l, c}) do
    # (blocks of lines tested whole first, as a search does)
    block_re = Motion.block_regex(re)

    l..(Buffer.line_count(b) - 1)//1
    |> Stream.chunk_every(256)
    |> Enum.find_value(fn block ->
      text = Enum.map_join(block, "\n", &Buffer.line(b, &1))
      if block_re == nil or Regex.match?(block_re, text), do: Enum.find_value(block, &match_in_line(b, re, &1, l, c))
    end)
  end

  defp match_in_line(b, re, n, l, c) do
    line = Buffer.line(b, n)
    start = if n == l, do: c, else: 0
    offset = byte_size(String.slice(line, 0, start))

    case Regex.run(re, line, return: :index, offset: offset) do
      [{bs, bl} | _] when bs <= byte_size(line) ->
        a = String.length(binary_part(line, 0, bs))
        {n, a, a + String.length(binary_part(line, bs, bl))}

      _ ->
        nil
    end
  end

  defp query_key(%{query: q} = st, key) do
    {l, a, z} = q.at

    case key do
      k when k in ["y", "SPC"] -> st |> replace_match(l, a, z) |> next_after_replace()
      k when k in ["n", "DEL"] -> next_match(st, past(buf(st), l, a, z))
      "." -> st |> replace_match(l, a, z) |> finish_query()
      "!" -> st |> replace_match(l, a, z) |> replace_rest()
      k when k in ["q", "ESC", "C-g", "RET"] -> finish_query(st)
      _ -> query_prompt(st)
    end
  end

  defp replace_match(%{query: q} = st, l, a, z) do
    st = snapshot(st)
    b = buf(st)
    line = Buffer.line(b, l)
    matched = String.slice(line, a, z - a)
    new = Regex.replace(q.re, matched, q.to, global: false)
    line = String.slice(line, 0, a) <> new <> String.slice(line, z..-1//1)
    st = put_buf(st, Buffer.replace_lines(b, l, l, [line]))
    %{st | query: %{q | at: {l, a, a + String.length(new)}, replaced: q.replaced + 1, changed: MapSet.put(q.changed, buf(st).id)}}
  end

  defp next_after_replace(%{query: %{at: {l, a, z}}} = st), do: next_match(st, past(buf(st), l, a, z))

  # Where to look after a match: its end; after an empty one (^, $), the next
  # character, or the next line.
  defp past(b, l, a, z) do
    cond do
      z > a -> {l, z}
      a < Buffer.line_length(b, l) -> {l, a + 1}
      true -> {l + 1, 0}
    end
  end

  # !: every match left, in this buffer and the remaining files.
  defp replace_rest(%{query: %{at: {l, a, z}}} = st), do: replace_rest(st, past(buf(st), l, a, z))

  # Each buffer in one pass, one edit (one undo step): a match at a time
  # was 265,000 edits for a 10 MB file, 45 seconds, and more undo steps
  # than undo keeps, so u couldn't bring it back.
  defp replace_rest(st, from) do
    st = replace_all_from(st, from)

    case st.query.files do
      [] -> finish_query(st)
      [path | rest] -> st |> Map.put(:query, %{st.query | files: rest}) |> visit(path) |> replace_rest({0, 0})
    end
  end

  # The rest of a line the cursor is partway along: a match at a time (so
  # that ^ and lookbehinds see the whole line); then the lines below.
  defp replace_all_from(%{query: q} = st, {l, c}) when c > 0 do
    case match_in_line(buf(st), q.re, l, l, c) do
      {_, a, z} ->
        st = replace_match(st, l, a, z)
        {_, a2, z2} = st.query.at
        replace_all_from(st, past(buf(st), l, a2, z2))

      nil ->
        replace_all_from(st, {l + 1, 0})
    end
  end

  defp replace_all_from(%{query: q} = st, {l, _}) do
    b = buf(st)
    last = Buffer.line_count(b) - 1

    {lines, count} =
      Buffer.get_lines(b, l, last)
      |> Enum.map_reduce(0, fn line, count ->
        case Regex.scan(q.re, line, return: :index) do
          [] -> {line, count}
          found -> {Regex.replace(q.re, line, q.to), count + length(found)}
        end
      end)

    if count == 0 do
      st
    else
      st = snapshot(st)
      st = put_buf(st, Buffer.replace_lines(buf(st), l, last, lines))
      %{st | query: %{q | replaced: q.replaced + count, changed: MapSet.put(q.changed, buf(st).id)}}
    end
  end

  defp finish_query(%{query: q} = st) do
    files = MapSet.size(q.changed)
    text = "Replaced #{q.replaced} occurrence#{if q.replaced == 1, do: "", else: "s"} in #{files} file#{if files == 1, do: "", else: "s"}"
    msg(%{st | query: nil}, if(files > 0, do: text <> " (not saved: :wa or SPC f S saves them)", else: text))
  end

  def goto_grep_result(st) do
    b = buf(st)
    {l, _} = cursor(st)

    case Regex.run(~r/^([^:]+):(\d+):/, Buffer.line(b, l)) do
      [_, file, n] -> st |> visit(Path.join(b.meta.root, file)) |> set_cursor({String.to_integer(n) - 1, 0})
      _ -> st
    end
  end

  # -- drawing ---------------------------------------------------------------------------------

  defp redraw(st, full) do
    st = if full, do: %{st | frame: []}, else: st
    {frame, cursor_pos} = Render.frame(st)
    out = Render.diff(st.frame, frame)
    cursor_seq = case cursor_pos do
      {r, c} -> "\e[#{r + 1};#{c + 1}H\e[?25h"
      nil -> "\e[?25l"
    end

    shape = if st.mode in [:insert, :replace] or st.minibuffer, do: "\e[6 q", else: "\e[2 q"
    TTY.write(st.tty, ["\e[?25l", out, cursor_seq, shape])
    %{st | frame: frame}
  end

  # exposed for Ex / Magit / Render
  @doc false
  def api(st, :put_buf, b), do: put_buf(st, b)
  def api(st, :set_cursor, pos), do: set_cursor(st, pos)
  def api(st, :snapshot, _), do: snapshot(st)
  def api(st, :msg, text), do: msg(st, text)
  def api(st, :error, text), do: msg(st, text, true)
  def api(st, :visit, path), do: visit(st, path)
  def api(st, :save, _), do: save(st)
  def api(st, :save_repo_buffers, root), do: save_repo_buffers(st, root)
  def api(st, :quit_window, force), do: quit_window(st, force)
  def api(st, :split, dir), do: split(st, dir)
  def api(st, :cursor, _), do: cursor(st)
  def api(st, :prompt, {kind, label, initial}), do: prompt(st, kind, label, initial)
  def api(st, :dir, _), do: dir_of(st)
  def api(st, :kill_buffer, id), do: kill_buffer(st, id)
  def api(st, :show_buffer, id), do: show_buffer(st, id)
  def api(st, :add_buffer, b), do: add_buffer(st, b)
  def api(st, :region_lines, _), do: region_lines(st)
  def api(st, :grep_result, _), do: goto_grep_result(st)
  def api(st, :cycle, dir), do: cycle_buffer(st, dir)
end
