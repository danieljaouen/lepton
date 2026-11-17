defmodule Lepton.Mux do
  @moduledoc """
  `tmux` for Lepton: sessions, windows and panes, driven by the user's
  `~/.tmux.conf`.

  A session is a `Lepton.Mux.Server` process supervised independently of
  any terminal, so it survives detaching (`prefix d`) and can be
  re-attached with `tmux attach`. Each pane runs a shell on its own
  `Lepton.TTY` whose output is interpreted by a `Lepton.Screen`.
  """

  alias Lepton.{IO, Keys}
  alias Lepton.Mux.{Client, Config, Server}

  @registry Lepton.Mux.Registry

  def sessions do
    for {{:session, name}, pid} <- registry_entries(), Process.alive?(pid), do: {name, pid}
  end

  defp registry_entries do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  rescue
    _ -> []
  end

  def find(name), do: Enum.find_value(sessions(), fn {n, pid} -> if n == name, do: pid end)

  def cli(args, ctx) do
    case args do
      [] -> new_session(ctx, nil, nil)
      [cmd | rest] when cmd in ["new", "new-session"] ->
        {opts, command} = Lepton.Args.getopt(rest, "s:n:dc:")
        new_session(ctx, opts["s"], if(command == [], do: nil, else: Enum.join(command, " ")), opts)

      [cmd | rest] when cmd in ["a", "at", "attach", "attach-session"] ->
        {opts, _} = Lepton.Args.getopt(rest, "t:d")

        case opts["t"] && find(opts["t"]) || (sessions() |> List.last() |> then(&(&1 && elem(&1, 1)))) do
          nil -> IO.err(ctx, "no sessions"); 1
          pid -> attach(ctx, pid)
        end

      [cmd | _] when cmd in ["ls", "list-sessions"] ->
        case sessions() do
          [] -> IO.err(ctx, "no server running on /tmp/tmux-0/default"); 1
          list ->
            for {name, pid} <- list do
              info = Server.info(pid)
              IO.puts(ctx, "#{name}: #{info.windows} windows (created by Lepton)#{if info.attached > 0, do: " (attached)", else: ""}")
            end

            0
        end

      [cmd | rest] when cmd in ["kill-session"] ->
        {opts, _} = Lepton.Args.getopt(rest, "t:")
        case find(opts["t"] || "") do
          nil -> IO.err(ctx, "can't find session: #{opts["t"]}"); 1
          pid -> Server.stop(pid); 0
        end

      ["kill-server" | _] ->
        for {_, pid} <- sessions(), do: Server.stop(pid)
        0

      [cmd | _] when cmd in ["list-keys", "lsk"] ->
        Lepton.Dotfiles.describe(ctx, "tmux")

      [cmd | _] when cmd in ["source-file", "source"] ->
        IO.puts(ctx, "configuration is read from ~/.tmux.conf when a client attaches")
        0

      _ ->
        IO.err(ctx, "usage: tmux [new [-s NAME] [CMD] | attach [-t NAME] | ls | kill-session -t NAME | kill-server | list-keys]")
        1
    end
  end

  defp new_session(ctx, name, command, opts \\ %{}) do
    cond do
      Map.has_key?(ctx.env, "TMUX") && !opts["d"] ->
        IO.err(ctx, "sessions should be nested with care, unset $TMUX to force")
        1

      name && find(name) ->
        IO.err(ctx, "duplicate session: #{name}")
        1

      true ->
        name = name || next_name()
        size = Lepton.TTY.size(ctx.tty)
        {:ok, pid} = DynamicSupervisor.start_child(Lepton.SessionSupervisor, {Server, name: name, ctx: ctx, size: size, command: command, window_name: opts["n"]})
        if opts["d"], do: 0, else: attach(ctx, pid)
    end
  end

  defp next_name do
    taken = MapSet.new(sessions(), &elem(&1, 0))
    Stream.iterate(0, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(taken, to_string(&1)))) |> to_string()
  end

  def attach(ctx, pid) do
    cfg = Config.load(Lepton.Ctx.home(ctx))
    Client.run(ctx, pid, cfg)
  end

  @doc """
  Spacemacs tmux layer support: called by the editor when `C-h/j/k/l`
  reaches the edge of its windows. If the editor runs in a pane, select
  the neighbouring pane.
  """
  def navigate_from(tty, dir) do
    case Registry.lookup(@registry, {:pane_tty, tty}) do
      [{server, pane_id}] ->
        flag = %{left: "-L", right: "-R", up: "-U", down: "-D"}[dir]
        Server.exec(server, ["select-pane", flag, "-t", "%#{pane_id}"])
        :ok

      _ ->
        :not_in_mux
    end
  end

  @doc "Encode a key for delivery to a pane's program."
  def encode_key(key), do: Keys.encode(key)
end

defmodule Lepton.Mux.PaneBackend do
  @moduledoc false
  # TTY backend for multiplexer panes: output goes to the session server.
  def open({server, pane_id, size}, _tty), do: {:ok, {server, pane_id, size}}
  def size({_server, _id, size}), do: size
  def write({server, id, _}, data), do: send(server, {:pane_output, id, data})
end

defmodule Lepton.Mux.Server do
  @moduledoc "A multiplexer session: windows, panes, layouts and pane processes."

  use GenServer, restart: :temporary

  alias Lepton.{Screen, TTY}
  alias Lepton.Mux.{Layout, PaneBackend}

  @registry Lepton.Mux.Registry

  defmodule Window do
    @moduledoc false
    defstruct [:id, :index, :name, :layout, :active, :last, zoomed: nil, activity: false, auto_name: true]
  end

  defmodule Pane do
    @moduledoc false
    defstruct [:id, :screen, :tty, :proc, :cmd, :lepton_pid, dead: false]
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def info(pid), do: GenServer.call(pid, :info)
  def stop(pid), do: GenServer.cast(pid, :stop)
  def exec(pid, tokens), do: GenServer.call(pid, {:exec, tokens}, 30_000)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def key(pid, key), do: GenServer.cast(pid, {:key, key})
  def input(pid, bytes), do: GenServer.cast(pid, {:input, bytes})
  def attach(pid, client, size), do: GenServer.call(pid, {:attach, client, size})
  def detach(pid, client), do: GenServer.cast(pid, {:detach, client})
  def resize(pid, client, size), do: GenServer.cast(pid, {:resize, client, size})
  def options(pid), do: GenServer.call(pid, :options)

  @impl true
  def init(opts) do
    name = opts[:name]
    Registry.register(@registry, {:session, name}, nil)
    {rows, cols} = opts[:size] || {24, 80}
    cfg = Lepton.Mux.Config.load(Lepton.Ctx.home(opts[:ctx]))

    st = %{
      name: name,
      ctx: opts[:ctx],
      cfg: cfg,
      size: {max(rows - 1, 2), cols},
      windows: %{},
      active: nil,
      last: nil,
      panes: %{},
      next_id: 0,
      clients: %{},
      dirty_timer: nil,
      started: System.os_time(:second)
    }

    {st, _} = new_window(st, opts[:command], opts[:window_name], true)
    {:ok, st}
  end

  # -- calls -----------------------------------------------------------------------------

  @impl true
  def handle_call(:info, _from, st), do: {:reply, %{windows: map_size(st.windows), attached: map_size(st.clients), name: st.name}, st}
  def handle_call(:options, _from, st), do: {:reply, st.cfg.options, st}

  def handle_call({:attach, client, size}, _from, st) do
    Process.monitor(client)
    st = %{st | clients: Map.put(st.clients, client, size)} |> apply_size()
    {:reply, {:ok, st.name}, st}
  end

  def handle_call(:snapshot, _from, st) do
    win = st.windows[st.active]
    area = area(st)
    tree = if win.zoomed, do: {:pane, win.zoomed}, else: win.layout
    rects = Layout.rects(tree, area)

    panes =
      for {id, rect} <- rects, into: %{} do
        p = st.panes[id]
        {id, %{rect: rect, screen: p.screen, index: pane_index(win, id)}}
      end

    windows =
      st.windows
      |> Map.values()
      |> Enum.sort_by(& &1.index)
      |> Enum.map(&%{index: &1.index, name: &1.name, active: &1.id == st.active, last: &1.id == st.last, activity: &1.activity, zoomed: &1.zoomed != nil})

    {:reply, %{name: st.name, panes: panes, active_pane: win.active, windows: windows, size: st.size}, %{st | windows: Map.put(st.windows, win.id, %{win | activity: false})}}
  end

  def handle_call({:exec, tokens}, _from, st) do
    {reply, st} = run(tokens, st)
    st = notify(st)

    if st.windows == %{} do
      {:stop, :normal, {:exited, st.name}, st}
    else
      {:reply, reply, st}
    end
  end

  # -- casts & info --------------------------------------------------------------------------

  @impl true
  def handle_cast({:key, key}, st) do
    send_to_active(st, Lepton.Mux.encode_key(key))
    {:noreply, st}
  end

  def handle_cast({:input, bytes}, st) do
    send_to_active(st, bytes)
    {:noreply, st}
  end

  def handle_cast({:detach, client}, st), do: {:noreply, %{st | clients: Map.delete(st.clients, client)} |> apply_size()}
  def handle_cast({:resize, client, size}, st), do: {:noreply, %{st | clients: Map.put(st.clients, client, size)} |> apply_size() |> notify()}

  def handle_cast(:stop, st) do
    for {c, _} <- st.clients, do: send(c, {:mux_exit, st.name})
    for {_, p} <- st.panes, do: Process.exit(p.proc, :kill)
    {:stop, :normal, st}
  end

  @impl true
  def handle_info({:pane_output, id, data}, st) do
    case st.panes[id] do
      nil ->
        {:noreply, st}

      p ->
        screen = Screen.feed(p.screen, data)
        st = put_in(st.panes[id], %{p | screen: screen})
        st = mark_activity(st, id) |> rename_from_title(id, screen)
        {:noreply, schedule_notify(st)}
    end
  end

  def handle_info(:notify, st), do: {:noreply, notify(%{st | dirty_timer: nil})}

  def handle_info({:DOWN, _, :process, pid, _}, st) do
    cond do
      Map.has_key?(st.clients, pid) ->
        {:noreply, %{st | clients: Map.delete(st.clients, pid)} |> apply_size()}

      pane = Enum.find(Map.values(st.panes), &(&1.proc == pid)) ->
        st = close_pane(st, pane.id)

        if st.windows == %{} do
          for {c, _} <- st.clients, do: send(c, {:mux_exit, st.name})
          {:stop, :normal, st}
        else
          {:noreply, notify(st)}
        end

      true ->
        {:noreply, st}
    end
  end

  def handle_info(_, st), do: {:noreply, st}

  defp schedule_notify(%{dirty_timer: nil} = st), do: %{st | dirty_timer: Process.send_after(self(), :notify, 15)}
  defp schedule_notify(st), do: st

  defp notify(st) do
    for {c, _} <- st.clients, do: send(c, :mux_dirty)
    st
  end

  defp mark_activity(st, id) do
    case Enum.find(Map.values(st.windows), &(id in Layout.panes(&1.layout))) do
      %{id: wid} = w when wid != st.active ->
        if st.cfg.options["monitor-activity"] == "on", do: put_in(st.windows[wid], %{w | activity: true}), else: st

      _ ->
        st
    end
  end

  # automatic-rename: name windows after the program setting the title.
  defp rename_from_title(st, _id, %{title: nil}), do: st
  defp rename_from_title(st, id, %{title: title}) do
    case Enum.find(Map.values(st.windows), &(&1.active == id and &1.auto_name)) do
      nil -> st
      w -> put_in(st.windows[w.id], %{w | name: title |> String.split(" ") |> hd() |> String.slice(0, 20)})
    end
  end

  defp send_to_active(st, bytes) do
    with w when w != nil <- st.windows[st.active], p when p != nil <- st.panes[w.active] do
      TTY.input(p.tty, bytes)
    end
  end

  # -- sizes -----------------------------------------------------------------------------------

  defp area(st) do
    {rows, cols} = st.size
    {0, 0, cols, rows}
  end

  # The session takes the smallest attached client's size (tmux default).
  defp apply_size(st) do
    size =
      case Map.values(st.clients) do
        [] -> st.size
        sizes -> {sizes |> Enum.map(&elem(&1, 0)) |> Enum.min() |> Kernel.-(1) |> max(2), sizes |> Enum.map(&elem(&1, 1)) |> Enum.min()}
      end

    relayout(%{st | size: size})
  end

  defp relayout(st) do
    Enum.reduce(st.windows, st, fn {_, w}, st ->
      tree = if w.zoomed, do: {:pane, w.zoomed}, else: w.layout
      rects = Layout.rects(tree, area(st))

      Enum.reduce(rects, st, fn {id, {_x, _y, cw, ch}}, st ->
        p = st.panes[id]

        if p && {p.screen.rows, p.screen.cols} != {ch, cw} do
          TTY.set_size(p.tty, {ch, cw})
          put_in(st.panes[id], %{p | screen: Screen.resize(p.screen, ch, cw)})
        else
          st
        end
      end)
    end)
  end

  # -- panes & windows ------------------------------------------------------------------------

  defp new_pane(st, command, size) do
    id = st.next_id
    {rows, cols} = size
    history = st.cfg.options["history-limit"] |> to_string() |> Integer.parse() |> then(fn {n, _} -> n; :error -> 2000 end)
    {:ok, tty} = TTY.start(backend: {PaneBackend, {self(), id, {rows, cols}}}, name: "pane %#{id}", term: "screen-256color")
    Registry.register(@registry, {:pane_tty, tty}, id)
    ctx = st.ctx

    env =
      ctx.env
      |> Map.put("TMUX", "/tmp/tmux-0/default,#{inspect(self())},#{st.name}")
      |> Map.put("TMUX_PANE", "%#{id}")
      |> Map.put("TERM", "screen-256color")
      # Remember what the real terminal is (glyph choices like the prompt arrow).
      |> Map.put("LEPTON_OUTER_TERM", ctx.env["LEPTON_OUTER_TERM"] || ctx.env["TERM"] || "xterm")
      |> Map.put("COLUMNS", to_string(cols))
      |> Map.put("LINES", to_string(rows))

    pane_ctx = %{ctx | env: env, stdin: tty, stdout: tty, stderr: tty, tty: tty}
    title = command || "lsh"

    {lpid, proc, _ref} =
      Lepton.Proc.spawn(title, [tty: tty, monitor: true], fn pid ->
        pane_ctx = %{pane_ctx | pid: pid}

        if command do
          Lepton.Shell.run_string(command, cwd: pane_ctx.cwd, env: env, stdin: tty, stdout: tty, stderr: tty, tty: tty, rc: true, user: pane_ctx.user)
        else
          Lepton.Shell.interactive(pane_ctx)
        end
      end)

    pane = %Pane{id: id, screen: Screen.new(rows, cols, history_limit: history), tty: tty, proc: proc, cmd: command, lepton_pid: lpid}
    {%{st | panes: Map.put(st.panes, id, pane), next_id: id + 1}, id}
  end

  defp new_window(st, command, name, select) do
    {rows, cols} = st.size
    {st, pane} = new_pane(st, command, {rows, cols})
    base = st.cfg.options["base-index"] |> to_string() |> String.to_integer()
    taken = st.windows |> Map.values() |> Enum.map(& &1.index) |> MapSet.new()
    index = Stream.iterate(base, &(&1 + 1)) |> Enum.find(&(not MapSet.member?(taken, &1)))
    wid = "w#{st.next_id}-#{index}"
    win = %Window{id: wid, index: index, name: name || command_name(command), layout: {:pane, pane}, active: pane, last: nil, auto_name: name == nil}
    st = %{st | windows: Map.put(st.windows, wid, win)}
    st = if select or st.active == nil, do: %{st | last: st.active, active: wid}, else: st
    {st, wid}
  end

  defp command_name(nil), do: "lsh"
  defp command_name(cmd), do: cmd |> String.split() |> hd() |> Path.basename()

  defp close_pane(st, id) do
    pane = st.panes[id]
    if pane, do: Registry.unregister(@registry, {:pane_tty, pane.tty})
    if pane && Process.alive?(pane.tty), do: GenServer.stop(pane.tty, :normal)
    st = %{st | panes: Map.delete(st.panes, id)}

    case Enum.find(Map.values(st.windows), &(id in Layout.panes(&1.layout))) do
      nil -> st
      w ->
        case Layout.remove(w.layout, id) do
          nil -> remove_window(st, w.id)
          layout ->
            remaining = Layout.panes(layout)
            active = if w.active == id, do: (if w.last in remaining, do: w.last, else: hd(remaining)), else: w.active
            put_in(st.windows[w.id], %{w | layout: layout, active: active, zoomed: nil}) |> relayout()
        end
    end
  end

  defp remove_window(st, wid) do
    windows = Map.delete(st.windows, wid)

    active =
      cond do
        st.active != wid -> st.active
        st.last && Map.has_key?(windows, st.last) -> st.last
        true -> windows |> Map.values() |> Enum.sort_by(& &1.index) |> List.first() |> then(&(&1 && &1.id))
      end

    %{st | windows: windows, active: active, last: if(st.last == wid or st.last == active, do: nil, else: st.last)}
  end

  defp kill_pane_proc(st, id) do
    case st.panes[id] do
      nil -> st
      p ->
        Process.demonitor(Process.monitor(p.proc))
        Process.exit(p.proc, :kill)
        close_pane(st, id)
    end
  end

  defp pane_index(win, id), do: Enum.find_index(Layout.panes(win.layout), &(&1 == id))

  # -- targets -------------------------------------------------------------------------------

  defp sorted_windows(st), do: st.windows |> Map.values() |> Enum.sort_by(& &1.index)

  defp find_window(st, nil), do: st.windows[st.active]

  defp find_window(st, target) do
    target = target |> String.split(":", parts: 2) |> then(fn [_, w] -> w; [w] -> w end)
    target = target |> String.split(".") |> hd()
    wins = sorted_windows(st)
    idx = Enum.find_index(wins, &(&1.id == st.active))

    case target do
      "" -> st.windows[st.active]
      "+" -> Enum.at(wins, rem(idx + 1, length(wins)))
      "-" -> Enum.at(wins, rem(idx - 1 + length(wins), length(wins)))
      "!" -> st.windows[st.last]
      "=" <> n -> Enum.find(wins, &(to_string(&1.index) == n))
      t ->
        Enum.find(wins, &(to_string(&1.index) == t)) || Enum.find(wins, &(&1.name == t)) || Enum.find(wins, &String.starts_with?(&1.name, t))
    end
  end

  defp find_pane(st, nil), do: {st.windows[st.active], st.windows[st.active].active}

  defp find_pane(st, "%" <> id) do
    id = String.to_integer(id)
    w = Enum.find(Map.values(st.windows), &(id in Layout.panes(&1.layout)))
    {w, id}
  end

  defp find_pane(st, target) do
    {win_part, pane_part} =
      case String.split(target, ".", parts: 2) do
        [w, p] -> {w, p}
        [w] -> {w, nil}
      end

    w = if win_part in ["", ":"], do: st.windows[st.active], else: find_window(st, win_part)

    case {w, pane_part} do
      {nil, _} -> {nil, nil}
      {w, nil} -> {w, w.active}
      {w, "+"} -> ids = Layout.panes(w.layout); {w, Enum.at(ids, rem(pane_index(w, w.active) + 1, length(ids)))}
      {w, "-"} -> ids = Layout.panes(w.layout); {w, Enum.at(ids, rem(pane_index(w, w.active) - 1 + length(ids), length(ids)))}
      {w, n} -> {w, Enum.at(Layout.panes(w.layout), String.to_integer(n))}
    end
  end

  # -- commands ------------------------------------------------------------------------------

  defp run([cmd | args], st), do: command(cmd, args, st)
  defp run([], st), do: {:ok, st}

  defp command(cmd, args, st) when cmd in ["split-window", "splitw"] do
    {opts, rest} = Lepton.Args.getopt(args, "hvdbfp:l:c:t:")
    dir = if opts["h"], do: :h, else: :v
    {w, target} = find_pane(st, opts["t"])
    rects = Layout.rects(w.layout, area(st))
    {_, _, pw, ph} = rects[target]
    total = if dir == :h, do: pw, else: ph

    pct =
      cond do
        p = opts["p"] -> String.to_integer(p)
        l = opts["l"] -> l |> String.trim_trailing("%") |> String.to_integer() |> then(&if(String.ends_with?(l, "%"), do: &1, else: div(&1 * 100, max(total, 1))))
        true -> 50
      end

    new_size = if dir == :h, do: {ph, max(div(pw * pct, 100), 1)}, else: {max(div(ph * pct, 100), 1), pw}
    command = if rest == [], do: nil, else: Enum.join(rest, " ")
    {st, id} = new_pane(st, command, new_size)
    layout = Layout.split(w.layout, target, dir, id, pct, opts["b"] == true)
    w = %{w | layout: layout, zoomed: nil}
    w = if opts["d"], do: w, else: %{w | last: w.active, active: id}
    {:ok, put_in(st.windows[w.id], w) |> relayout()}
  end

  defp command(cmd, args, st) when cmd in ["new-window", "neww"] do
    {opts, rest} = Lepton.Args.getopt(args, "dn:c:t:")
    command = if rest == [], do: nil, else: Enum.join(rest, " ")
    {st, _} = new_window(st, command, opts["n"], opts["d"] != true)
    {:ok, relayout(st)}
  end

  defp command(cmd, args, st) when cmd in ["select-pane", "selectp"] do
    {opts, _} = Lepton.Args.getopt(args, "LRUDlt:Z")
    {w, target} = find_pane(st, opts["t"])

    cond do
      w == nil ->
        {{:error, "can't find pane"}, st}

      opts["l"] ->
        if w.last, do: {:ok, put_in(st.windows[w.id], %{w | active: w.last, last: w.active})}, else: {:ok, st}

      dir = Enum.find_value([{"L", :left}, {"R", :right}, {"U", :up}, {"D", :down}], fn {f, d} -> opts[f] && d end) ->
        tree = if w.zoomed, do: {:pane, w.zoomed}, else: w.layout
        next = Layout.neighbor(tree, area(st), target, dir)
        st = if w.id != st.active, do: %{st | last: st.active, active: w.id}, else: st
        {:ok, put_in(st.windows[w.id], %{w | active: next, last: if(next != w.active, do: w.active, else: w.last)})}

      true ->
        st = if w.id != st.active, do: %{st | last: st.active, active: w.id}, else: st
        {:ok, put_in(st.windows[w.id], %{w | active: target, last: if(target != w.active, do: w.active, else: w.last)})}
    end
  end

  defp command("last-pane", _args, st), do: command("select-pane", ["-l"], st)

  defp command(cmd, args, st) when cmd in ["select-window", "selectw"] do
    {opts, _} = Lepton.Args.getopt(args, "t:lnp")

    target =
      cond do
        opts["n"] -> find_window(st, "+")
        opts["p"] -> find_window(st, "-")
        opts["l"] -> st.windows[st.last]
        true -> find_window(st, opts["t"])
      end

    select_window(st, target)
  end

  defp command(cmd, _args, st) when cmd in ["next-window", "next"], do: select_window(st, find_window(st, "+"))
  defp command(cmd, _args, st) when cmd in ["previous-window", "prev"], do: select_window(st, find_window(st, "-"))
  defp command(cmd, _args, st) when cmd in ["last-window", "last"], do: select_window(st, st.last && st.windows[st.last])

  defp command(cmd, args, st) when cmd in ["kill-pane", "killp"] do
    {opts, _} = Lepton.Args.getopt(args, "t:a")
    {_w, id} = find_pane(st, opts["t"])
    {:ok, kill_pane_proc(st, id)}
  end

  defp command(cmd, args, st) when cmd in ["kill-window", "killw"] do
    {opts, _} = Lepton.Args.getopt(args, "t:a")

    case find_window(st, opts["t"]) do
      nil -> {{:error, "can't find window: #{opts["t"]}"}, st}
      w -> {:ok, Enum.reduce(Layout.panes(w.layout), st, &kill_pane_proc(&2, &1))}
    end
  end

  defp command("kill-session", _args, st) do
    st = Enum.reduce(Map.keys(st.panes), st, &kill_pane_proc(&2, &1))
    {:ok, st}
  end

  defp command(cmd, args, st) when cmd in ["rename-window", "renamew"] do
    {opts, rest} = Lepton.Args.getopt(args, "t:")

    case {find_window(st, opts["t"]), rest} do
      {nil, _} -> {{:error, "can't find window"}, st}
      {w, [name | _]} -> {:ok, put_in(st.windows[w.id], %{w | name: name, auto_name: false})}
      _ -> {:ok, st}
    end
  end

  defp command(cmd, [name | _], st) when cmd in ["rename-session", "rename"] do
    Registry.unregister(@registry, {:session, st.name})
    Registry.register(@registry, {:session, name}, nil)
    {:ok, %{st | name: name}}
  end

  defp command(cmd, args, st) when cmd in ["select-layout", "selectl"] do
    {_opts, rest} = Lepton.Args.getopt(args, "t:")
    w = st.windows[st.active]
    ids = Layout.panes(w.layout)

    layout =
      case List.first(rest) || "tiled" do
        "tiled" -> Layout.tiled(ids)
        "even-horizontal" -> Layout.even(ids, :h)
        "even-vertical" -> Layout.even(ids, :v)
        "main-vertical" -> Layout.main_vertical(ids)
        "main-horizontal" -> case ids do
            [m | r] when r != [] -> {:split, :v, [{{:pane, m}, 60}, {Layout.even(r, :h), 40}]}
            _ -> Layout.even(ids, :v)
          end
        _ -> w.layout
      end

    {:ok, put_in(st.windows[w.id], %{w | layout: layout, zoomed: nil}) |> relayout()}
  end

  defp command("next-layout", _args, st) do
    w = st.windows[st.active]
    layouts = ["even-horizontal", "even-vertical", "main-vertical", "tiled"]
    i = Map.get(w, :layout_cycle, -1)
    next = rem(i + 1, length(layouts))
    {:ok, st} = command("select-layout", [Enum.at(layouts, next)], st)
    {:ok, put_in(st.windows[w.id], Map.put(st.windows[w.id], :layout_cycle, next))}
  end

  defp command(cmd, args, st) when cmd in ["resize-pane", "resizep"] do
    {opts, rest} = Lepton.Args.getopt(args, "LRUDZt:x:y:")
    {w, id} = find_pane(st, opts["t"])
    n = case rest do
      [n | _] -> String.to_integer(n)
      [] -> 1
    end

    cond do
      opts["Z"] ->
        zoomed = if w.zoomed, do: nil, else: (if length(Layout.panes(w.layout)) > 1, do: id, else: nil)
        {:ok, put_in(st.windows[w.id], %{w | zoomed: zoomed}) |> relayout()}

      dir = Enum.find_value([{"L", :left}, {"R", :right}, {"U", :up}, {"D", :down}], fn {f, d} -> opts[f] && d end) ->
        layout = Layout.resize(w.layout, area(st), id, dir, n)
        {:ok, put_in(st.windows[w.id], %{w | layout: layout}) |> relayout()}

      true ->
        {:ok, st}
    end
  end

  # swap-pane works across windows, which the user's zoom bindings
  # (prefix + / prefix -) rely on.
  defp command(cmd, args, st) when cmd in ["swap-pane", "swapp"] do
    {opts, _} = Lepton.Args.getopt(args, "s:t:UDd")
    {w, cur} = find_pane(st, nil)

    {{sw, src}, {dw, dst}} =
      cond do
        opts["U"] || opts["D"] ->
          ids = Layout.panes(w.layout)
          i = Enum.find_index(ids, &(&1 == cur))
          j = if opts["U"], do: rem(i - 1 + length(ids), length(ids)), else: rem(i + 1, length(ids))
          {{w, cur}, {w, Enum.at(ids, j)}}

        true ->
          {find_pane(st, opts["s"] || "%#{cur}"), find_pane(st, opts["t"] || "%#{cur}")}
      end

    cond do
      sw == nil or dw == nil or src == nil or dst == nil -> {{:error, "can't find pane"}, st}
      src == dst -> {:ok, st}
      sw.id == dw.id ->
        w2 = %{sw | layout: Layout.swap(sw.layout, src, dst), active: if(opts["d"], do: sw.active, else: (if sw.active == src, do: dst, else: (if sw.active == dst, do: src, else: sw.active)))}
        {:ok, put_in(st.windows[sw.id], w2) |> relayout()}

      true ->
        sw2 = %{sw | layout: Layout.rename(sw.layout, src, dst), active: if(sw.active == src, do: dst, else: sw.active), zoomed: nil}
        dw2 = %{dw | layout: Layout.rename(dw.layout, dst, src), active: if(dw.active == dst, do: src, else: dw.active), zoomed: nil}
        st = %{st | windows: st.windows |> Map.put(sw.id, sw2) |> Map.put(dw.id, dw2)}
        {:ok, relayout(st)}
    end
  end

  defp command("rotate-window", _args, st) do
    w = st.windows[st.active]
    ids = Layout.panes(w.layout)

    case ids do
      [_] -> {:ok, st}
      _ ->
        rotated = [List.last(ids) | Enum.drop(ids, -1)]
        mapping = Enum.zip(ids, rotated) |> Map.new()
        layout = Enum.reduce(ids, w.layout, fn id, l -> Layout.rename(l, id, {:tmp, mapping[id]}) end)
        layout = Enum.reduce(ids, layout, fn id, l -> Layout.rename(l, {:tmp, id}, id) end)
        {:ok, put_in(st.windows[w.id], %{w | layout: layout}) |> relayout()}
    end
  end

  defp command("break-pane", _args, st) do
    w = st.windows[st.active]

    if length(Layout.panes(w.layout)) < 2 do
      {:ok, st}
    else
      id = w.active
      layout = Layout.remove(w.layout, id)
      remaining = Layout.panes(layout)
      st = put_in(st.windows[w.id], %{w | layout: layout, active: hd(remaining), zoomed: nil})
      index = (st.windows |> Map.values() |> Enum.map(& &1.index) |> Enum.max()) + 1
      wid = "w#{st.next_id}-#{index}-b"
      nw = %Window{id: wid, index: index, name: "lsh", layout: {:pane, id}, active: id}
      {:ok, %{st | windows: Map.put(st.windows, wid, nw), last: st.active, active: wid, next_id: st.next_id + 1} |> relayout()}
    end
  end

  defp command(cmd, args, st) when cmd in ["set", "set-option", "setw", "set-window-option"] do
    {_f, rest} = Enum.split_with(args, &String.starts_with?(&1, "-"))

    case rest do
      [k, v | _] -> {:ok, put_in(st.cfg.options[k], v)}
      _ -> {:ok, st}
    end
  end

  defp command(cmd, _args, st), do: {{:error, "unknown command: #{cmd}"}, st}

  defp select_window(st, nil), do: {{:error, "can't find window"}, st}
  defp select_window(st, %{id: id}) when id == st.active, do: {:ok, st}
  defp select_window(st, w), do: {:ok, %{st | last: st.active, active: w.id, windows: Map.put(st.windows, w.id, %{w | activity: false})} |> relayout()}

  @impl true
  def terminate(_reason, st) do
    for {_, p} <- st.panes, Process.alive?(p.tty), do: GenServer.stop(p.tty, :normal)
    :ok
  end
end
