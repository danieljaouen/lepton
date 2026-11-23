defmodule Lepton.MuxTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.{Keys, Screen}
  alias Lepton.Mux.{Config, Layout}

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(100); eventually(fun, tries - 1)
    end
  end

  describe "layout" do
    test "splits and rectangles" do
      tree = {:pane, 0} |> Layout.split(0, :h, 1) |> Layout.split(1, :v, 2)
      rects = Layout.rects(tree, {0, 0, 81, 24})
      assert rects[0] == {0, 0, 40, 24}
      assert {41, 0, 40, _} = rects[1]
      assert {41, _, 40, _} = rects[2]
    end

    test "split -p 25 gives the new pane a quarter" do
      tree = Layout.split({:pane, 0}, 0, :v, 1, 25)
      %{1 => {_, _, _, h}} = Layout.rects(tree, {0, 0, 80, 41})
      assert h == 10
    end

    test "neighbors, tiled layout, swap and remove" do
      tree = Layout.tiled([0, 1, 2, 3])
      area = {0, 0, 80, 24}
      assert Layout.neighbor(tree, area, 0, :right) == 1
      assert Layout.neighbor(tree, area, 0, :down) == 2
      assert Layout.neighbor(tree, area, 0, :left) == 1
      assert Layout.panes(Layout.swap(tree, 0, 3)) == [3, 1, 2, 0]
      assert Layout.panes(Layout.remove(tree, 1)) == [0, 2, 3]
    end

    test "resize moves the shared border" do
      tree = Layout.split({:pane, 0}, 0, :h, 1)
      area = {0, 0, 81, 24}
      grown = Layout.resize(tree, area, 0, :right, 5)
      assert {0, 0, 45, 24} = Layout.rects(grown, area)[0]
      shrunk = Layout.resize(tree, area, 0, :left, 5)
      assert {0, 0, 35, 24} = Layout.rects(shrunk, area)[0]
    end
  end

  describe "screen emulator" do
    test "text, cursor movement and erase" do
      s = Screen.new(5, 20) |> Screen.feed("hello\r\nworld\e[1;1HJ\e[2;3H\e[K")
      assert Screen.row_text(s, 0) == "Jello"
      assert Screen.row_text(s, 1) == "wo"
    end

    test "SGR attributes and rendering" do
      s = Screen.new(2, 10) |> Screen.feed("\e[1;31mred\e[0m ok")
      assert {"r", "1;31"} = Screen.cell(s, 0, 0)
      assert Screen.cell(s, 4, 0) == {"o", ""}
      assert Screen.render_row(s, 0) =~ "\e[0;1;31mred"
    end

    test "scrolling keeps scrollback; alternate screen restores" do
      s = Screen.new(2, 10) |> Screen.feed("a\r\nb\r\nc")
      assert Screen.row_text(s, 0) == "b"
      assert length(s.scrollback) == 1
      s = s |> Screen.feed("\e[?1049hFULL") |> Screen.feed("\e[?1049l")
      assert Screen.row_text(s, 1) == "c"
    end

    test "wide input is split across feeds" do
      s = Screen.new(2, 10) |> Screen.feed("\e[3") |> Screen.feed("1mX")
      assert {"X", "31"} = Screen.cell(s, 0, 0)
    end

    # What Claude Code writes: kitty keyboard flags pushed and popped,
    # modifyOtherKeys, queries, and tmux passthrough (it sees TMUX).
    test "private, intermediate and string sequences draw nothing and move nothing" do
      seqs = ["\e[>1u", "\e[<u", "\e[?u", "\e[=1;1u", "\e[>4;2m", "\e[?2026$p", "\eP>|xterm\e\\", "\e_Gi=1;OK\e\\", "\e[1;2\x01"]

      for q <- seqs do
        s = Screen.new(2, 20) |> Screen.feed("ab\e[s" <> q <> "X")
        assert {Screen.text(s) |> String.trim(), s.x, s.sgr, s.pending} == {"abX", 3, "", ""}, inspect(q)
      end

      # Split across writes, a string waits for its end.
      s = Screen.new(2, 20) |> Screen.feed("\eP>|xt") |> Screen.feed("erm\e\\Y")
      assert Screen.text(s) |> String.trim() == "Y"

      # tmux's passthrough: what it wraps takes effect.
      s = Screen.new(2, 20) |> Screen.feed("\ePtmux;\e\e]2;hello\e\e\\\e\\Z")
      assert s.title == "hello" and Screen.text(s) |> String.trim() == "Z"
    end
  end

  describe "keys" do
    test "decode escape sequences into kbd names" do
      assert {["C-t", "a", "<up>", "M-x", "RET", "DEL"], ""} = Keys.decode(<<20, ?a, 27, ?[, ?A, 27, ?x, 13, 127>>)
      assert {[], <<27>>} = Keys.decode(<<27>>)
      assert Keys.flush(<<27>>) == ["ESC"]
    end

    test "encode/normalize round trip" do
      for k <- ["C-t", "a", "<up>", "RET", "C-<left>", "M-x"], do: assert(Keys.decode(Keys.encode(k)) == {[k], ""})
      assert Keys.normalize("^W") == "C-w"
      assert Keys.normalize("^x") == "C-x"
    end
  end

  describe "tmux.conf" do
    test "tokenizer handles quotes and \; chains" do
      assert Config.commands(~s|split-window -p 25 'vim .' \; swap-pane -D|) == [["split-window", "-p", "25", "vim ."], ["swap-pane", "-D"]]
    end

    @tag :dotfiles
    test "the user's tmux.conf: prefix, bindings, repeat and copy mode" do
      cfg = Config.load(dotfiles_home())
      assert cfg.options["prefix"] == "C-t"
      assert cfg.options["mode-keys"] == "vi"
      assert cfg.options["history-limit"] == "100000"
      p = cfg.tables["prefix"]
      assert p["v"].cmd == "split-window -h"
      assert p["s"].cmd == "split-window -v"
      assert p["h"].cmd == "select-pane -L"
      assert p["C-t"].cmd == "send-prefix"
      assert p["H"] == %{cmd: "resize-pane -L 5", repeat: true}
      assert p["C-l"] == %{cmd: "select-window -t :+", repeat: true}
      # K is bound twice in the user's file; like tmux, the later
      # `bind-key -r K resize-pane -U 5` wins over `bind K confirm-before ...`.
      assert p["K"] == %{cmd: "resize-pane -U 5", repeat: true}
      assert p["C-x"].cmd == "kill-pane"
      assert p["="].cmd == "select-layout tiled"
      assert p["C-w"].cmd =~ "split-window -p 25 'vim .'"
      refute Map.has_key?(p, "C-b")
      vi = cfg.tables["copy-mode-vi"]
      assert vi["v"].cmd == "send-keys -X begin-selection"
      assert vi["y"].cmd == "send-keys -X copy-selection"
      # if-shell "uname | grep -q Linux" sources tmux.linux.conf on Lepton
      assert vi["Y"].cmd =~ "xclip"
      assert cfg.options["@themepack"] == "powerline/default/cyan"
    end
  end

  describe "sessions" do
    test "a session runs a shell in a pane and survives detach" do
      ctx = %Lepton.Ctx{cwd: tmp_dir("mux"), env: %{"HOME" => dotfiles_home(), "NO_COLOR" => "1"}}
      {:ok, pid} = DynamicSupervisor.start_child(Lepton.SessionSupervisor, {Lepton.Mux.Server, name: "t#{System.unique_integer([:positive])}", ctx: ctx, size: {24, 80}, command: "echo pane-ok; read"})
      Process.sleep(300)
      snap = Lepton.Mux.Server.snapshot(pid)
      [pane] = Map.values(snap.panes)
      assert Screen.text(pane.screen) =~ "pane-ok"
      assert :ok = Lepton.Mux.Server.exec(pid, ["split-window", "-h"])
      assert map_size(Lepton.Mux.Server.snapshot(pid).panes) == 2
      assert :ok = Lepton.Mux.Server.exec(pid, ["new-window", "-n", "second"])
      assert length(Lepton.Mux.Server.snapshot(pid).windows) == 2
      Lepton.Mux.Server.stop(pid)
    end

    test "kill-pane stops what the pane's shell started too" do
      ctx = %Lepton.Ctx{cwd: tmp_dir("mux"), env: %{"HOME" => dotfiles_home(), "NO_COLOR" => "1"}}
      {:ok, pid} = DynamicSupervisor.start_child(Lepton.SessionSupervisor, {Lepton.Mux.Server, name: "t#{System.unique_integer([:positive])}", ctx: ctx, size: {24, 80}, command: "sleep 601"})
      Process.sleep(300)
      sleeping = fn -> Enum.filter(Lepton.Proc.list(), &(&1.cmd =~ "sleep 601" and &1.tty != nil)) end
      assert [_ | _] = procs = sleeping.()
      assert :ok = Lepton.Mux.Server.exec(pid, ["split-window", "-h"])
      assert :ok = Lepton.Mux.Server.exec(pid, ["select-pane", "-L"])
      assert :ok = Lepton.Mux.Server.exec(pid, ["kill-pane"])
      Process.sleep(200)
      refute Enum.any?(procs, &Process.alive?(&1.beam))
      assert sleeping.() == []
      Lepton.Mux.Server.stop(pid)
    end

    # A client on a terminal of our own (its output comes here) with
    # `mouse on`; le in one of two panes.
    defmodule TestTerm do
      @moduledoc false
      def open({pid, size}, _tty), do: {:ok, {pid, size}}
      def size({_, size}), do: size
      def write({pid, _}, data), do: send(pid, {:client_out, data})
    end

    test "mouse on: a click selects the pane under it, and reaches le there, at the pane's cells" do
      dir = tmp_dir("muxmouse")
      File.write!(Path.join(dir, "f.txt"), Enum.map_join(1..30, "\n", &"line #{&1} of text") <> "\n")
      ctx = %Lepton.Ctx{cwd: dir, env: %{"HOME" => dotfiles_home(), "NO_COLOR" => "1"}}
      {:ok, pid} = DynamicSupervisor.start_child(Lepton.SessionSupervisor, {Lepton.Mux.Server, name: "m#{System.unique_integer([:positive])}", ctx: ctx, size: {24, 80}, command: "le f.txt"})
      :ok = Lepton.Mux.Server.exec(pid, ["split-window", "-h", "read"])
      {:ok, tty} = Lepton.TTY.start(backend: {TestTerm, {self(), {24, 80}}}, name: "mux test")
      cfg = %{Config.defaults() | options: Map.put(Config.defaults().options, "mouse", "on")}
      me = self()
      client = spawn(fn -> Lepton.Mux.Client.run(%{ctx | tty: tty, stdout: tty}, pid, cfg); send(me, :client_done) end)
      # The client turns the terminal's mouse reports on.
      assert_receive {:client_out, "\e[?1002h\e[?1006h"}, 5000

      snap = fn -> Lepton.Mux.Server.snapshot(pid) end
      [{le_id, _}] = Enum.filter(snap.().panes, fn {_, p} -> elem(p.rect, 0) == 0 end)
      assert snap.().active_pane != le_id
      assert eventually(fn -> le_pane = snap.().panes[le_id]; le_pane.screen.mouse == :drag and Lepton.Screen.text(le_pane.screen) =~ "line 3 of text" end)
      # (le draws line numbers in 4 columns: "line 3" starts at column 4.)
      click = fn x, y -> Lepton.TTY.input(tty, "\e[<0;#{x + 1};#{y + 1}M\e[<0;#{x + 1};#{y + 1}m") end

      # The first click selects le's pane; it gets that click too: its cursor is there.
      click.(4 + 5, 2)
      assert eventually(fn -> snap.().active_pane == le_id end)
      assert eventually(fn -> s = snap.().panes[le_id].screen; {s.x, s.y} == {9, 2} end)
      click.(4 + 2, 6)
      assert eventually(fn -> s = snap.().panes[le_id].screen; {s.x, s.y} == {6, 6} end)

      # A click in the other pane selects it; `read` didn't ask for the mouse, so it gets nothing.
      {px, _, _, _} = elem(Enum.find(snap.().panes, fn {id, _} -> id != le_id end), 1).rect
      click.(px + 3, 3)
      assert eventually(fn -> snap.().active_pane != le_id end)

      Process.exit(client, :kill)
      Lepton.Mux.Server.stop(pid)
    end

    @tag :dotfiles
    test "the user's zoom bindings (prefix + / prefix -) work as written" do
      cfg = Config.load(dotfiles_home())
      ctx = %Lepton.Ctx{cwd: tmp_dir("zoom"), env: %{"HOME" => dotfiles_home(), "NO_COLOR" => "1"}}
      {:ok, pid} = DynamicSupervisor.start_child(Lepton.SessionSupervisor, {Lepton.Mux.Server, name: "z#{System.unique_integer([:positive])}", ctx: ctx, size: {24, 80}, command: "read"})
      :ok = Lepton.Mux.Server.exec(pid, ["split-window", "-h", "read"])
      before = Lepton.Mux.Server.snapshot(pid)
      zoomed_pane = before.active_pane

      run = fn key ->
        for cmd <- Config.commands(cfg.tables["prefix"][key].cmd), do: :ok = Lepton.Mux.Server.exec(pid, cmd)
      end

      run.("+")
      snap = Lepton.Mux.Server.snapshot(pid)
      assert Enum.find(snap.windows, & &1.active).name == "tmux-zoom"
      # the pane is now alone in the zoom window, at full width
      assert %{^zoomed_pane => %{rect: {0, 0, 80, _}}} = snap.panes

      run.("-")
      snap = Lepton.Mux.Server.snapshot(pid)
      assert length(snap.windows) == 1
      assert Map.has_key?(snap.panes, zoomed_pane)
      assert map_size(snap.panes) == 2
      Lepton.Mux.Server.stop(pid)
    end
  end
end
