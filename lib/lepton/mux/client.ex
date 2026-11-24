defmodule Lepton.Mux.Client do
  @moduledoc """
  An attached multiplexer client: owns the real terminal, interprets keys
  through the tmux key tables (prefix, root, copy-mode-vi) with `-r`
  repeat, runs UI commands (prompts, confirmations, copy mode, pickers)
  and renders panes, borders and the status line.

  With `mouse on` (as in tmux), the terminal reports the mouse: a click
  selects the pane under it, and what a pane's program asked for (`le`
  does) reaches it, at the pane's own cells.
  """

  alias Lepton.{Clipboard, Keys, Screen, TTY}
  alias Lepton.Mux.{Config, Server}

  defstruct [:server, :name, :cfg, :tty, :ctx, :size, :snapshot, mode: :normal, message: nil, frame: [], result: nil]

  def run(ctx, server, cfg) do
    tty = ctx.tty
    TTY.set_mode(tty, :raw)
    TTY.write(tty, "\e[?1049h\e[?25l\e[H\e[2J")
    {:ok, name} = Server.attach(server, self(), TTY.size(tty))
    if mouse?(cfg), do: TTY.write(tty, "\e[?1002h\e[?1006h")
    # Pastes come marked (bracketed), and go on to the pane as its program wants them.
    TTY.write(tty, "\e[?2004h")
    me = self()
    reader = spawn_link(fn -> read_loop(tty, me) end)
    st = %__MODULE__{server: server, name: name, cfg: cfg, tty: tty, ctx: ctx, size: TTY.size(tty)}

    result =
      try do
        st |> title() |> render() |> loop()
      after
        Process.unlink(reader)
        Process.exit(reader, :kill)
        TTY.write(tty, "\e[?1002l\e[?1006l\e[?2004l\e[0m\e[?25h\e[2 q\e[?1049l")
        TTY.set_mode(tty, :cooked)
      end

    case result do
      {:detached, n} -> Lepton.IO.puts(ctx, "[detached (from session #{n})]")
      {:switch, pid} -> Lepton.Mux.attach(ctx, pid)
      _ -> Lepton.IO.puts(ctx, "[exited]")
    end

    0
  end

  defp read_loop(tty, client) do
    send(client, {:client_key, TTY.read_key(tty)})
    read_loop(tty, client)
  end

  defp loop(%{result: r}) when r != nil, do: r

  defp loop(st) do
    receive do
      {:client_key, key} ->
        st |> handle_key(key) |> maybe_render() |> loop()

      :mux_dirty ->
        drain_dirty()
        st |> render() |> loop()

      {:mux_exit, _name} ->
        :exited
    after
      1000 ->
        st |> check_size() |> expire_message() |> render() |> loop()
    end
  end

  defp drain_dirty do
    receive do
      :mux_dirty -> drain_dirty()
    after
      0 -> :ok
    end
  end

  defp maybe_render(%{result: nil} = st), do: render(st)
  defp maybe_render(st), do: st

  defp check_size(st) do
    size = TTY.size(st.tty)

    if size != st.size do
      Server.resize(st.server, self(), size)
      %{st | size: size, frame: []}
    else
      st
    end
  end

  defp expire_message(%{message: {_, until}} = st) do
    if System.monotonic_time(:millisecond) > until, do: %{st | message: nil}, else: st
  end

  defp expire_message(st), do: st

  defp message(st, text), do: %{st | message: {text, System.monotonic_time(:millisecond) + 1500}}

  defp prefix(st), do: Keys.normalize(st.cfg.options["prefix"] || "C-b")

  # -- keys ----------------------------------------------------------------------------------

  defp handle_key(st, {:cpr, _, _}), do: st
  defp handle_key(st, {:resize, _, _}), do: check_size(st)
  defp handle_key(st, {:mouse, _, _, _, _, _} = m), do: mouse(st, m)
  defp handle_key(st, {:paste, text}), do: paste(st, text)

  defp handle_key(st, key) do
    case st.mode do
      :normal -> normal_key(st, key)
      :prefix -> prefix_key(st, key)
      {:repeat, until} -> repeat_key(st, key, until)
      {:prompt, p} -> prompt_key(st, p, key)
      {:confirm, c} -> confirm_key(st, c, key)
      {:copy, c} -> Lepton.Mux.CopyMode.key(st, c, key)
      {:choose, c} -> choose_key(st, c, key)
      {:view, v} -> view_key(st, v, key)
      {:panes, _} -> panes_key(st, key)
      :clock -> %{st | mode: :normal}
    end
  end

  defp normal_key(st, key) do
    cond do
      key == prefix(st) -> %{st | mode: :prefix}
      b = st.cfg.tables["root"][key] -> exec_string(st, b.cmd)
      true -> Server.key(st.server, key); st
    end
  end

  defp prefix_key(st, key) do
    case st.cfg.tables["prefix"][key] do
      nil -> %{st | mode: :normal}
      %{cmd: cmd, repeat: true} -> exec_string(%{st | mode: {:repeat, deadline(st)}}, cmd) |> keep_repeat()
      %{cmd: cmd} -> exec_string(%{st | mode: :normal}, cmd)
    end
  end

  # After a -r binding, further repeatable keys work without the prefix.
  defp repeat_key(st, key, until) do
    binding = st.cfg.tables["prefix"][key]

    cond do
      System.monotonic_time(:millisecond) <= until and binding != nil and binding.repeat ->
        exec_string(%{st | mode: {:repeat, deadline(st)}}, binding.cmd) |> keep_repeat()

      true ->
        normal_key(%{st | mode: :normal}, key)
    end
  end

  defp keep_repeat(%{mode: {:repeat, _}} = st), do: st
  defp keep_repeat(st), do: st

  defp deadline(st) do
    ms = st.cfg.options["repeat-time"] |> to_string() |> Integer.parse() |> then(fn {n, _} -> n; :error -> 500 end)
    System.monotonic_time(:millisecond) + ms
  end

  # -- pasting ---------------------------------------------------------------------------------

  # As tmux: a pane whose program asked for bracketed paste gets the paste
  # marked; another gets its newlines as Return. (Only in the normal mode.)
  defp paste(%{mode: :normal, snapshot: %{panes: panes, active_pane: id}} = st, text) do
    bracketed? = match?(%{screen: %{bracketed_paste: true}}, panes[id])
    Server.input(st.server, if(bracketed?, do: Keys.encode({:paste, text}), else: text |> String.replace("\r\n", "\r") |> String.replace("\n", "\r")))
    st
  end

  defp paste(st, _text), do: st

  # -- the mouse -------------------------------------------------------------------------------

  defp mouse?(cfg), do: cfg.options["mouse"] == "on"

  # A press selects the pane under the pointer; the pane's program gets
  # the report if it asked (relative to the pane), as long as the pointer
  # is over the active pane. Only in the normal mode.
  defp mouse(%{mode: :normal, snapshot: %{panes: panes}} = st, {:mouse, action, button, x, y, mods}) do
    hit = Enum.find(panes, fn {_id, %{rect: {px, py, w, h}}} -> x >= px and x < px + w and y >= py and y < py + h end)

    case hit do
      nil ->
        st

      {id, %{rect: {px, py, _, _}, screen: scr}} ->
        st =
          if action == :press and id != st.snapshot.active_pane,
            do: exec(st, ["select-pane", "-t", "%#{id}"]) |> then(&%{&1 | snapshot: safe_snapshot(&1) || &1.snapshot}),
            else: st

        if id == st.snapshot.active_pane and Keys.wants_mouse?(scr.mouse, action),
          do: Server.input(st.server, Keys.mouse_report({:mouse, action, button, x - px, y - py, mods}, scr.mouse_sgr))

        st
    end
  end

  defp mouse(st, _), do: st

  # -- running commands -----------------------------------------------------------------------

  def exec_string(st, string) do
    string
    |> Config.commands()
    |> Enum.reduce_while(st, fn cmd, st ->
      st = exec(st, cmd)
      if st.result || match?({m, _} when m in [:prompt, :confirm], st.mode), do: {:halt, st}, else: {:cont, st}
    end)
  end

  defp exec(st, [cmd | args]) do
    case cmd do
      c when c in ["send-prefix"] ->
        Server.key(st.server, prefix(st))
        st

      c when c in ["command-prompt"] ->
        {opts, rest} = Lepton.Args.getopt(args, "p:I:")
        label = (opts["p"] || ":") |> then(&if(String.ends_with?(&1, " "), do: &1, else: &1 <> " "))
        initial = format(st, opts["I"] || "")
        template = if rest == [], do: "%%", else: Enum.join(rest, " ")
        prev = if match?({:copy, _}, st.mode), do: st.mode, else: :normal
        %{st | mode: {:prompt, %{label: if(opts["p"], do: "(" <> String.trim(label) <> ") ", else: ":"), text: initial, template: template, prev: prev}}}

      c when c in ["confirm-before", "confirm"] ->
        {opts, rest} = Lepton.Args.getopt(args, "p:")
        command = Enum.join(rest, " ")
        label = format(st, opts["p"] || "#{command}? (y/n)")
        %{st | mode: {:confirm, %{label: label, cmd: command}}}

      c when c in ["copy-mode"] ->
        Lepton.Mux.CopyMode.enter(st, "-u" in args)

      c when c in ["detach-client", "detach"] ->
        Server.detach(st.server, self())
        %{st | result: {:detached, st.name}}

      c when c in ["switch-client", "switchc"] ->
        switch(st, args)

      c when c in ["choose-tree", "choose-session", "choose-window", "choose-client"] ->
        choose(st, if(c == "choose-window" or "-w" in args, do: :windows, else: :sessions))

      c when c in ["list-keys", "lsk"] ->
        lines =
          for {table, binds} <- Enum.sort(st.cfg.tables), {k, b} <- Enum.sort(binds) do
            "bind-key #{if b.repeat, do: "-r ", else: "   "}-T #{String.pad_trailing(table, 13)} #{String.pad_trailing(k, 10)} #{b.cmd}"
          end

        %{st | mode: {:view, %{lines: lines, top: 0, title: "list-keys"}}}

      c when c in ["list-buffers", "choose-buffer", "lsb"] ->
        lines = Clipboard.all() |> Enum.with_index() |> Enum.map(fn {t, i} -> "buffer#{i}: #{byte_size(t)} bytes: \"#{t |> String.replace("\n", "\\n") |> String.slice(0, 60)}\"" end)
        %{st | mode: {:view, %{lines: if(lines == [], do: ["(no buffers)"], else: lines), top: 0, title: "buffers"}}}

      c when c in ["display-panes", "displayp"] ->
        %{st | mode: {:panes, System.monotonic_time(:millisecond) + 1000}}

      "clock-mode" ->
        %{st | mode: :clock}

      c when c in ["display-message", "display"] ->
        message(st, format(st, Enum.join(Enum.reject(args, &String.starts_with?(&1, "-")), " ") |> then(&if(&1 == "", do: "[#S] #I:#P \"#H\" %H:%M %d-%b-%y", else: &1))))

      c when c in ["source-file", "source"] ->
        path = args |> Enum.reject(&String.starts_with?(&1, "-")) |> List.first()
        home = Lepton.Ctx.home(st.ctx)
        path = String.replace_prefix(path || "~/.tmux.conf", "~", home)
        %{st | cfg: Config.source(Config.defaults(), path, home)}

      c when c in ["refresh-client", "refresh"] ->
        %{st | frame: []}

      c when c in ["paste-buffer", "pasteb"] ->
        Server.input(st.server, Clipboard.get())
        st

      c when c in ["send-keys", "send"] ->
        {opts, keys} = Lepton.Args.getopt(args, "lXt:")

        case {opts["X"], st.mode} do
          {true, {:copy, copy}} ->
            Lepton.Mux.CopyMode.x(st, copy, keys)

          {true, _} ->
            st

          _ ->
            for k <- keys, do: if(opts["l"], do: Server.input(st.server, k), else: Server.key(st.server, Keys.normalize(k)))
            st
        end

      "if-shell" ->
        {_f, rest} = Enum.split_with(args, &String.starts_with?(&1, "-"))

        case rest do
          [test, yes | no] ->
            ok = Lepton.Shell.run_string(test, cwd: st.ctx.cwd, env: st.ctx.env, stdout: elem(StringIO.open(""), 1), user: st.ctx.user) == 0
            branch = if ok, do: yes, else: List.first(no)
            if branch, do: exec_string(st, branch), else: st

          _ ->
            st
        end

      c when c in ["run-shell", "run"] ->
        {out, _} = Lepton.Shell.run_capture(Enum.join(args, " "), cwd: st.ctx.cwd, env: st.ctx.env, user: st.ctx.user)
        if String.trim(out) == "", do: st, else: message(st, String.trim(out))

      "kill-server" ->
        for {_, pid} <- Lepton.Mux.sessions(), do: Server.stop(pid)
        %{st | result: :exited}

      _ ->
        case Server.exec(st.server, [cmd | args]) do
          :ok -> st
          {:error, msg} -> message(st, msg)
          {:exited, _} -> %{st | result: :exited}
        end
    end
  catch
    :exit, _ -> %{st | result: :exited}
  end

  defp exec(st, []), do: st

  defp switch(st, args) do
    {opts, _} = Lepton.Args.getopt(args, "npt:l")
    sessions = Lepton.Mux.sessions()
    idx = Enum.find_index(sessions, fn {_, pid} -> pid == st.server end) || 0

    target =
      cond do
        opts["n"] -> Enum.at(sessions, rem(idx + 1, length(sessions)))
        opts["p"] -> Enum.at(sessions, rem(idx - 1 + length(sessions), length(sessions)))
        t = opts["t"] -> Enum.find(sessions, fn {n, _} -> n == t end)
        true -> nil
      end

    case target do
      {_, pid} when pid != st.server ->
        Server.detach(st.server, self())
        %{st | result: {:switch, pid}}

      nil ->
        message(st, "can't find session")

      _ ->
        st
    end
  end

  def format(st, text) do
    snap = st.snapshot
    win = snap && Enum.find(snap.windows, & &1.active)
    pane = snap && snap.panes[snap.active_pane]

    text
    |> String.replace("#S", st.name)
    |> String.replace("#W", (win && win.name) || "")
    |> String.replace("#I", to_string((win && win.index) || 0))
    |> String.replace("#P", to_string((pane && pane.index) || 0))
    |> String.replace("#H", Lepton.Sys.hostname())
    |> String.replace("#h", Lepton.Sys.hostname() |> String.split(".") |> hd())
    |> then(&Lepton.Commands.System.strftime(Lepton.Time.local(), &1))
  end

  # -- prompts ---------------------------------------------------------------------------------

  defp prompt_key(st, p, key) do
    case key do
      k when k in ["RET", "C-j"] ->
        cmd = String.replace(p.template, "%%", p.text) |> String.replace("%1", p.text)
        exec_string(%{st | mode: p.prev}, cmd)

      k when k in ["ESC", "C-c", "C-g"] -> %{st | mode: p.prev}
      k when k in ["DEL", "C-h"] -> %{st | mode: {:prompt, %{p | text: String.slice(p.text, 0..-2//1)}}}
      "C-w" -> %{st | mode: {:prompt, %{p | text: Regex.replace(~r/\S*\s*$/, String.trim_trailing(p.text), "")}}}
      "C-u" -> %{st | mode: {:prompt, %{p | text: ""}}}
      k ->
        case Keys.text(k) do
          nil -> st
          t -> %{st | mode: {:prompt, %{p | text: p.text <> t}}}
        end
    end
  end

  defp confirm_key(st, c, key) do
    if key in ["y", "Y"], do: exec_string(%{st | mode: :normal}, c.cmd), else: %{st | mode: :normal}
  end

  # -- choose-tree -------------------------------------------------------------------------------

  defp choose(st, kind) do
    items =
      case kind do
        :sessions ->
          for {name, pid} <- Lepton.Mux.sessions() do
            info = Server.info(pid)
            {"(#{if pid == st.server, do: "*", else: " "}) #{name}: #{info.windows} windows#{if info.attached > 0, do: " (attached)", else: ""}", {:session, pid}}
          end

        :windows ->
          for w <- st.snapshot.windows, do: {"(#{w.index}) #{w.name}#{if w.active, do: "*", else: ""}", {:window, w.index}}
      end

    sel = Enum.find_index(items, fn {label, _} -> String.contains?(label, "*") end) || 0
    %{st | mode: {:choose, %{items: items, sel: sel}}}
  end

  defp choose_key(st, c, key) do
    n = length(c.items)

    case key do
      k when k in ["j", "<down>", "C-n"] -> %{st | mode: {:choose, %{c | sel: min(c.sel + 1, n - 1)}}}
      k when k in ["k", "<up>", "C-p"] -> %{st | mode: {:choose, %{c | sel: max(c.sel - 1, 0)}}}
      k when k in ["q", "ESC", "C-c", "C-g"] -> %{st | mode: :normal}
      "RET" ->
        case Enum.at(c.items, c.sel) do
          {_, {:session, pid}} when pid != st.server -> Server.detach(st.server, self()); %{st | mode: :normal, result: {:switch, pid}}
          {_, {:window, idx}} -> exec(%{st | mode: :normal}, ["select-window", "-t", ":=#{idx}"])
          _ -> %{st | mode: :normal}
        end

      _ -> st
    end
  end

  defp view_key(st, v, key) do
    {rows, _} = st.size

    case key do
      k when k in ["q", "ESC", "C-c"] -> %{st | mode: :normal}
      k when k in ["j", "<down>", "RET"] -> %{st | mode: {:view, %{v | top: min(v.top + 1, max(length(v.lines) - rows + 2, 0))}}}
      k when k in ["k", "<up>"] -> %{st | mode: {:view, %{v | top: max(v.top - 1, 0)}}}
      k when k in ["SPC", "C-f", "C-d"] -> %{st | mode: {:view, %{v | top: min(v.top + rows - 2, max(length(v.lines) - rows + 2, 0))}}}
      k when k in ["b", "C-b", "C-u"] -> %{st | mode: {:view, %{v | top: max(v.top - rows + 2, 0)}}}
      _ -> st
    end
  end

  defp panes_key(st, key) do
    st = %{st | mode: :normal}

    if key =~ ~r/^\d$/ do
      exec(st, ["select-pane", "-t", ":." <> key])
    else
      handle_key(st, key)
    end
  end

  # -- rendering -----------------------------------------------------------------------------------

  defp title(st) do
    if st.cfg.options["set-titles"] == "on", do: TTY.write(st.tty, "\e]0;" <> format(%{st | snapshot: safe_snapshot(st)}, st.cfg.options["set-titles-string"] || "#S: #W") <> "\a")
    st
  end

  defp safe_snapshot(st) do
    Server.snapshot(st.server)
  catch
    :exit, _ -> nil
  end

  def render(st) do
    case safe_snapshot(st) do
      nil ->
        %{st | result: :exited}

      snap ->
        st = %{st | snapshot: snap}
        {rows, cols} = st.size
        {frame, cursor} = compose(st, snap, rows, cols)
        out = Lepton.Editor.Render.diff(st.frame, frame)

        cursor_seq =
          case cursor do
            {r, c} -> "\e[#{r + 1};#{c + 1}H\e[?25h"
            nil -> "\e[?25l"
          end

        TTY.write(st.tty, ["\e[?25l", out, cursor_seq])
        %{st | frame: frame}
    end
  end

  defp compose(st, snap, rows, cols) do
    area_rows = rows - 1

    case st.mode do
      {:view, v} ->
        lines = Enum.slice(v.lines, v.top, area_rows)
        body = for i <- 0..(area_rows - 1), do: "\e[0m" <> String.pad_trailing(String.slice(Enum.at(lines, i) || "", 0, cols), cols)
        {body ++ [status_line(st, snap, cols)], nil}

      {:choose, c} ->
        body =
          for i <- 0..(area_rows - 1) do
            case Enum.at(c.items, i) do
              nil -> String.duplicate(" ", cols)
              {label, _} -> if i == c.sel, do: "\e[7m" <> String.pad_trailing(label, cols) <> "\e[0m", else: String.pad_trailing(label, cols)
            end
          end

        {body ++ [status_line(st, snap, cols)], nil}

      _ ->
        panes(st, snap, area_rows, cols)
    end
  end

  defp panes(st, snap, area_rows, cols) do
    active = snap.active_pane
    theme = theme_color(st)
    borders = border_cells(snap.panes, area_rows, cols, active)

    copy = case st.mode do
      {:copy, c} -> c
      _ -> nil
    end

    rows =
      for y <- 0..(area_rows - 1) do
        segs =
          for {id, %{rect: {x, py, w, h}, screen: scr}} <- snap.panes, y >= py and y < py + h do
            text =
              cond do
                copy && id == active -> Lepton.Mux.CopyMode.render_row(copy, scr, y - py, w)
                st.mode == :clock and id == active -> clock_row(scr, y - py, w, h, theme)
                match?({:panes, _}, st.mode) and y - py == div(h, 2) -> pane_number_row(scr, y - py, w, snap.panes[id].index, id == active, theme)
                true -> Screen.render_row(scr, y - py, 0, w)
              end

            {x, text}
          end

        border_segs = for {{bx, ^y}, {ch, act}} <- borders, do: {bx, if(act, do: "\e[3#{theme}m#{ch}\e[0m", else: "\e[38;5;240m#{ch}\e[0m")}

        (segs ++ border_segs)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join(fn {x, text} -> "\e[#{y + 1};#{x + 1}H" <> text end)
      end

    cursor =
      case {st.mode, snap.panes[active]} do
        {{:copy, c}, %{rect: {x, y, _, _}}} -> Lepton.Mux.CopyMode.cursor(c, x, y)
        {{:prompt, p}, _} -> {area_rows, String.length(p.label <> p.text)}
        {_, %{rect: {x, y, _, _}, screen: scr}} -> if scr.cursor_visible and st.mode != :clock, do: {y + scr.y, x + scr.x}, else: nil
        _ -> nil
      end

    {rows ++ [status_line(st, snap, cols)], cursor}
  end

  # Border cells between panes: %{{x, y} => {char, touches_active?}}
  defp border_cells(panes, area_rows, cols, active) do
    cells =
      Enum.reduce(panes, %{}, fn {id, %{rect: {x, y, w, h}}}, acc ->
        acc =
          if x + w < cols do
            Enum.reduce(y..min(y + h, area_rows - 1), acc, fn yy, acc -> add_border(acc, {x + w, yy}, :v, id == active) end)
          else
            acc
          end

        if y + h < area_rows do
          Enum.reduce(x..min(x + w, cols - 1), acc, fn xx, acc -> add_border(acc, {xx, y + h}, :h, id == active) end)
        else
          acc
        end
      end)

    Map.new(cells, fn {pos, {kinds, act}} ->
      ch = cond do
        MapSet.size(kinds) == 2 -> "┼"
        MapSet.member?(kinds, :v) -> "│"
        true -> "─"
      end

      {pos, {ch, act}}
    end)
  end

  defp add_border(acc, pos, kind, act) do
    Map.update(acc, pos, {MapSet.new([kind]), act}, fn {k, a} -> {MapSet.put(k, kind), a or act} end)
  end

  # jimeh/tmux-themepack "powerline/default/<colour>" (the user's @themepack),
  # mapped onto the 8 base colours so it renders on the Linux console too.
  defp theme_color(st) do
    case st.cfg.options["@themepack"] do
      nil -> "2"
      theme ->
        case theme |> String.split("/") |> List.last() do
          "cyan" -> "6"
          "blue" -> "4"
          "green" -> "2"
          "red" -> "1"
          c when c in ["yellow", "orange"] -> "3"
          c when c in ["magenta", "purple"] -> "5"
          "gray" -> "7"
          _ -> "6"
        end
    end
  end

  defp status_line(st, snap, cols) do
    case st.mode do
      {:prompt, p} -> "\e[48;5;220;38;5;232m" <> String.pad_trailing(p.label <> p.text, cols) <> "\e[0m"
      {:confirm, c} -> "\e[48;5;220;38;5;232m" <> String.pad_trailing(c.label, cols) <> "\e[0m"
      _ ->
        case st.message do
          {text, _} -> "\e[48;5;220;38;5;232m" <> String.pad_trailing(String.slice(text, 0, cols), cols) <> "\e[0m"
          nil -> status_bar(st, snap, cols)
        end
    end
  end

  defp status_bar(st, snap, cols) do
    c = theme_color(st)
    linux = Map.get(st.ctx.env, "TERM") == "linux"
    sep = if linux, do: "", else: "▌"
    mode_flag = case st.mode do
      :prefix -> " ^ "
      {:repeat, _} -> " ^ "
      {:copy, _} -> " ⎘ " |> then(&if(linux, do: " C ", else: &1))
      _ -> ""
    end

    left = "\e[4#{c};30;1m #{st.name}#{mode_flag} \e[0m\e[3#{c};48;5;236m#{sep}\e[0m"
    left_len = String.length(st.name) + String.length(mode_flag) + 2 + String.length(sep)

    {wins, wins_len} =
      Enum.reduce(snap.windows, {"", 0}, fn w, {acc, len} ->
        flag = cond do
          w.active and w.zoomed -> "*Z"
          w.active -> "*"
          w.last -> "-"
          w.activity -> "#"
          true -> ""
        end

        label = " #{w.index}:#{w.name}#{flag} "
        styled = if w.active, do: "\e[4#{c};30;1m#{label}\e[0m", else: "\e[48;5;236;38;5;#{if w.activity, do: "214", else: "248"}m#{label}\e[0m"
        {acc <> styled, len + String.length(label)}
      end)

    now = Lepton.Time.local()
    right_text = " #{Lepton.Commands.System.strftime(now, "%H:%M")} #{sep} #{Lepton.Commands.System.strftime(now, "%d-%b-%y")} "
    host = " #{Lepton.Sys.hostname()} "
    right = "\e[48;5;238;38;5;250m#{right_text}\e[4#{c};30;1m#{host}\e[0m"
    right_len = String.length(right_text) + String.length(host)
    fill = max(cols - left_len - wins_len - right_len, 0)
    left <> wins <> "\e[48;5;236m" <> String.duplicate(" ", fill) <> "\e[0m" <> right
  end

  defp clock_row(_scr, y, w, h, theme) do
    {_, {hh, mm, _}} = Lepton.Time.erl()
    text = :io_lib.format("~2..0B:~2..0B", [hh, mm]) |> to_string()
    if y == div(h, 2) do
      centered = text |> String.pad_leading(div(w + 5, 2)) |> String.pad_trailing(w)
      "\e[3#{theme};1m" <> centered <> "\e[0m"
    else
      String.duplicate(" ", w)
    end
  end

  defp pane_number_row(_scr, _y, w, index, active, theme) do
    label = " #{index} "
    color = if active, do: "4" <> theme, else: "47"
    pad = max(div(w - 3, 2), 0)
    String.duplicate(" ", pad) <> "\e[#{color};30;1m#{label}\e[0m" <> String.duplicate(" ", max(w - pad - 3, 0))
  end
end
