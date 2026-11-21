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
  alias Lepton.Editor.{Buffer, Keymap, Motion, Render, Magit}

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
            message: nil,
            message_error: false,
            minibuffer: nil,
            search: nil,
            last_find: nil,
            visual_start: nil,
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
            insert_snapshot: false

  defmodule Win do
    @moduledoc false
    defstruct id: nil, buf: nil, cursor: {0, 0}, top: 0, left: 0, want_col: 0, jumps: []
  end

  @default_vars %{
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
  def run(files, ctx) do
    st = init(files, ctx)
    TTY.set_mode(ctx.tty, :raw)
    TTY.write(ctx.tty, "\e[?1049h\e[?25l")

    try do
      st |> redraw(true) |> loop()
      0
    after
      TTY.write(ctx.tty, "\e[0m\e[?25h\e[?1049l")
      TTY.set_mode(ctx.tty, :cooked)
    end
  end

  def init(files, ctx) do
    emacs = Lepton.Dotfiles.emacs(Lepton.Ctx.home(ctx))
    km = Keymap.build(emacs)
    vars = Map.merge(@default_vars, emacs.vars)
    vars = if emacs.themes != [], do: Map.put(vars, "theme", hd(emacs.themes)), else: vars
    vars = Map.put(vars, "line-numbers", vars["display-line-numbers-type"] not in [nil, false])

    st = %__MODULE__{km: km, vars: vars, emacs: emacs, ctx: ctx, tty: ctx.tty, size: if(ctx.tty, do: TTY.size(ctx.tty), else: {24, 80})}

    files = if files == [], do: [nil], else: files

    st =
      Enum.reduce(files, st, fn
        nil, st -> add_buffer(st, Buffer.new("*scratch*", ";; This buffer is for text that is not saved.\n", kind: :scratch, mode: "Text"))
        f, st -> open_path(st, Lepton.Ctx.path(ctx, f))
      end)

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
  def handle_key(st, key) do
    st = %{st | message: if(match?({:which_key, _}, st.message), do: nil, else: st.message)}
    st = if st.recording, do: %{st | recording: st.recording ++ [key]}, else: st

    cond do
      st.minibuffer -> minibuffer_key(st, key)
      st.mode in [:insert, :replace] -> insert_key(st, key)
      st.mode in [:visual, :visual_line] -> visual_key(st, key)
      buf(st).kind in [:magit, :dired, :help, :list, :log] -> special_key(st, key)
      true -> normal_key(st, key)
    end
  end

  # -- buffers & windows ------------------------------------------------------------------

  def buf(st), do: st.buffers[win(st).buf]
  def win(st), do: st.windows[st.active]
  defp put_buf(st, b), do: %{st | buffers: Map.put(st.buffers, b.id, b)}
  defp put_win(st, w), do: %{st | windows: Map.put(st.windows, w.id, w)}
  defp cursor(st), do: win(st).cursor

  defp set_cursor(st, {l, c}, opts \\ []) do
    b = buf(st)
    l = l |> max(0) |> min(Buffer.line_count(b) - 1)
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
    top = cond do
      l < w.top -> l
      l >= w.top + h -> l - h + 1
      true -> w.top
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

  # -- normal state ------------------------------------------------------------------------

  defp normal_key(st, key) do
    cond do
      st.pending == [] and st.operator == nil and key =~ ~r/^[1-9]$/ ->
        %{st | count: key_count(st.count, key)}

      st.pending == [] and st.count != nil and key =~ ~r/^[0-9]$/ ->
        %{st | count: key_count(st.count, key)}

      st.operator != nil ->
        operator_pending(st, key)

      true ->
        seq = st.pending ++ [key]

        case Keymap.lookup(st.km.normal, seq) do
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

  defp move(st, m) do
    {target, kind} = Motion.apply(buf(st), cursor(st), m, st.count, motion_ctx(st))
    st = remember_find(st, m)

    case kind do
      :none -> st
      :linewise when m in ["j", "k", "<up>", "<down>"] ->
        {l, _} = target
        w = win(st)
        set_cursor(st, {l, w.want_col}, keep_want: true)

      _ ->
        st = if m in ["G", "gg", "n", "N", "%", "{", "}"], do: push_jump(st), else: st
        set_cursor(st, target)
    end
  end

  defp remember_find(st, {k, ch}) when k in ["f", "F", "t", "T"], do: %{st | last_find: {k, ch}}
  defp remember_find(st, _), do: st

  defp motion_ctx(st) do
    w = win(st)
    %{view: {w.top, view_height(st)}, last_find: st.last_find, search: st.search}
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
              apply_operator(st, from, to, kind)
            end

          {:object, obj} ->
            case Motion.object(buf(st), cursor(st), obj) do
              {:range, from, to, kind} -> apply_operator(st, from, to, if(kind == :exclusive, do: :exclusive_range, else: kind))
              :none -> reset_op(st)
            end

          :invalid ->
            reset_op(st)
        end
    end
  end

  defp operator_keys(:delete), do: ["d"]
  defp operator_keys(:change), do: ["c"]
  defp operator_keys(:yank), do: ["y"]
  defp operator_keys(:indent), do: [">"]
  defp operator_keys(:dedent), do: ["<"]
  defp operator_keys(:reindent), do: ["="]
  defp operator_keys(op) when op in [:toggle_case, :downcase, :upcase], do: ["~", "u", "U", "g~", "gu", "gU"]

  defp reset_op(st), do: %{st | operator: nil, pending: [], count: nil, op_count: nil, recording: nil}

  defp order(a, b) when a <= b, do: {a, b}
  defp order(a, b), do: {b, a}

  # Ranges: :linewise uses whole lines from..to; :inclusive includes `to`;
  # :exclusive excludes it; :exclusive_range is an already-exclusive end.
  defp apply_operator(st, {fl, fc} = from, {tl, tc} = to, kind) do
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
              st = set_register(st, {:line, Buffer.get_lines(b, fl, tl)})
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
              st |> set_register({:char, text}) |> set_cursor(from)

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

  defp set_register(st, reg) do
    text = case reg do
      {:line, lines} -> Enum.join(lines, "\n") <> "\n"
      {:char, t} -> t
    end

    if text != "", do: Lepton.Clipboard.put(text)
    %{st | register: reg}
  end

  # -- change recording (for `.`) ------------------------------------------------------------

  @changing ~w(insert append insert_bol append_eol open_below open_above delete_char delete_char_before
               substitute_char substitute_line delete_eol change_eol paste_after paste_before join_lines
               replace_char toggle_case)a

  defp start_change_record(%{replaying: true} = st, _seq, _a), do: st
  defp start_change_record(st, seq, action) when action in @changing, do: %{st | recording: seq}
  defp start_change_record(st, _seq, _a), do: st

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

  def do_action(st, :open_below, _) do
    st = snapshot(st)
    {l, _} = cursor(st)
    indent = leading(Buffer.line(buf(st), l))
    st = put_buf(st, Buffer.insert_lines(buf(st), l + 1, [indent]))
    enter_insert(%{st | mode: :insert} |> set_cursor({l + 1, String.length(indent)}), false)
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

  def do_action(st, :replace_char, n) do
    case TTY.read_key(st.tty) do
      key when is_binary(key) ->
        case Keys.text(key) do
          nil -> st
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

      _ ->
        st
    end
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

  def do_action(st, :keyboard_quit, _), do: %{st | pending: [], count: nil, operator: nil} |> msg("Quit")
  def do_action(st, :redraw, _), do: %{st | frame: []}
  def do_action(st, :normal_state, _), do: %{st | mode: :normal}

  # files
  def do_action(st, :save, _), do: save(st)

  def do_action(st, :save_all, _) do
    Enum.reduce(st.order, st, fn id, st ->
      b = st.buffers[id]
      if b.modified and b.path, do: save_buffer(st, b) |> elem(1), else: st
    end)
    |> msg("Saved all buffers")
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

  def do_action(st, :comment_line, n) do
    {fl, tl} = if st.mode in [:visual, :visual_line], do: region_lines(st), else: {elem(cursor(st), 0), elem(cursor(st), 0) + (n || 1) - 1}
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
    st = snapshot(st)
    {l, c} = cursor(st)
    b = buf(st)

    case st.register do
      {:line, lines} ->
        lines = List.duplicate(lines, n) |> List.flatten()
        at = if where == :after, do: l + 1, else: l
        st |> put_buf(Buffer.insert_lines(b, at, lines)) |> set_cursor({at, Motion.first_non_blank(Buffer.insert_lines(b, at, lines), at)})

      {:char, text} ->
        text = String.duplicate(text, n)
        pos = if where == :after and Buffer.line_length(b, l) > 0, do: {l, c + 1}, else: {l, c}
        {b, {el, ec}} = Buffer.insert(b, pos, text)
        st |> put_buf(b) |> set_cursor({el, max(ec - 1, 0)})
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
        if result == :ok, do: msg(st, "Wrote #{Lepton.Ctx.tildify(st.ctx, b.path)}"), else: st
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
              {:motion, m} -> move(st, m) |> Map.put(:count, nil)
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
      :visual_line -> {{elem(a, 0), 0}, {elem(b, 0), 0}, :linewise}
      _ -> {a, b, :inclusive}
    end
  end

  defp region_lines(st) do
    if st.mode in [:visual, :visual_line] do
      {{fl, _}, {tl, _}, _} = region(st)
      {fl, tl}
    else
      {0, Buffer.line_count(buf(st)) - 1}
    end
  end

  defp leave_visual(st), do: %{st | last_visual: {st.mode, st.visual_start, cursor(st)}, mode: :normal, visual_start: nil}

  defp visual_action(st, action, count) do
    {from, to, kind} = region(st)

    case action do
      :normal_state -> leave_visual(st) |> then(&set_cursor(&1, cursor(&1)))
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
        reg = st.register
        st = leave_visual(st) |> Map.put(:operator, :delete) |> apply_operator(from, to, kind)
        %{st | register: reg} |> paste(:before, 1)

      :visual_insert -> leave_visual(st) |> set_cursor(from) |> enter_insert()
      :visual_append -> leave_visual(st) |> set_cursor({elem(to, 0), elem(to, 1) + 1}) |> enter_insert()
      a when a in [:sort_lines, :align_repeat, :comment_line, :delete_trailing_whitespace] -> do_action(st, a, count) |> then(&if(&1.mode in [:visual, :visual_line], do: leave_visual(&1), else: &1))
      :ex -> prompt(st, :ex, ":", "'<,'>")
      other -> do_action(leave_visual(st), other, count)
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
      :quoted_insert -> case TTY.read_key(st.tty) do
          k when is_binary(k) -> self_insert(st, Keys.encode(k))
          _ -> st
        end

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
        |> Buffer.lines()
        |> Enum.flat_map(&Regex.scan(~r/[\p{L}\p{N}_]{3,}/u, &1))
        |> Enum.map(&hd/1)
        |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 != prefix))
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

  defp project_files(st) do
    root = Lepton.Git.root(dir_of(st)) || dir_of(st)

    Path.wildcard(Path.join(root, "**/*"))
    |> Enum.reject(&(String.contains?(&1, "/.git/") or String.contains?(&1, "/_build/") or String.contains?(&1, "/deps/")))
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
  end

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
        set_cursor(st, pos)

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
