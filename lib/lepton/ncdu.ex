defmodule Lepton.Ncdu do
  @moduledoc """
  `ncdu`: disk usage, browsed. It scans a directory, then shows what is
  in it, largest first, with a bar for each entry's share of the
  directory; you go down into directories and back up, sort by size, name
  or item count, delete what you don't need, and rescan.

  Sizes are apparent sizes (what `ls -l` says). Each file is counted
  once, also through hard links; symlinks aren't followed; the kernel's
  file systems (/proc, /sys, /dev ...) are left out, and with `-x` so is
  anything on another file system.

  The browser is a state (`new/2`) that keys change (`key/2`) and that is
  drawn (`render/3`); `run/2` puts it on the terminal.
  """

  alias Lepton.TTY

  @kernfs ~w(proc sysfs devtmpfs devpts cgroup cgroup2 debugfs tracefs securityfs pstore bpf configfs fusectl mqueue hugetlbfs efivarfs binfmt_misc autofs rpc_pipefs nsfs)

  # -- scanning --------------------------------------------------------------------------------

  @doc """
  Scan `path`: `%{name, type, size, items, children, flag}` (a directory's
  children sorted by size). Options: `:one_fs` (don't cross into other
  file systems), `:progress` (a function called now and then with the
  items so far and the path being read).
  """
  def scan(path, opts \\ []) do
    path = Path.expand(path)

    excluded =
      for m <- Lepton.Sys.mounts(), m.type in @kernfs, m.dir != path, into: MapSet.new(), do: m.dir

    dev = case File.lstat(path) do
      {:ok, %{major_device: d}} -> d
      _ -> nil
    end

    ctx = %{excluded: excluded, one_fs: if(opts[:one_fs], do: dev), progress: opts[:progress]}
    Process.put({__MODULE__, :seen}, MapSet.new())
    Process.put({__MODULE__, :count}, 0)

    try do
      node(path, Path.basename(path) |> then(&if(&1 == "", do: "/", else: &1)), ctx)
    after
      Process.delete({__MODULE__, :seen})
      Process.delete({__MODULE__, :count})
    end
  end

  defp node(path, name, ctx) do
    count = Process.get({__MODULE__, :count}, 0) + 1
    Process.put({__MODULE__, :count}, count)
    if ctx.progress && rem(count, 500) == 0, do: ctx.progress.(count, path)

    case :file.read_link_info(String.to_charlist(path), [:raw, {:time, :posix}]) do
      {:ok, info} ->
        {:file_info, size, type, _access, _a, _m, _c, _mode, links, major, _minor, inode, _uid, _gid} = info

        cond do
          type == :directory and MapSet.member?(ctx.excluded, path) ->
            %{name: name, type: :directory, size: 0, items: 1, children: [], flag: "<"}

          type == :directory and ctx.one_fs != nil and major != ctx.one_fs ->
            %{name: name, type: :directory, size: 0, items: 1, children: [], flag: "<"}

          type == :directory ->
            case File.ls(path) do
              {:ok, names} ->
                # (in order of name: of hard links, the first one read gets the size)
                children = names |> Enum.sort() |> Enum.map(&node(Path.join(path, &1), &1, ctx)) |> sort(:size, :desc)
                flag = cond do
                  children == [] -> "e"
                  Enum.any?(children, &(&1.flag in ["!", "."])) -> "."
                  true -> " "
                end

                %{name: name, type: :directory, size: size + Enum.sum(Enum.map(children, & &1.size)), items: 1 + Enum.sum(Enum.map(children, & &1.items)), children: children, flag: flag}

              {:error, _} ->
                %{name: name, type: :directory, size: size, items: 1, children: [], flag: "!"}
            end

          type == :regular and links > 1 ->
            seen = Process.get({__MODULE__, :seen})
            key = {major, inode}

            if MapSet.member?(seen, key) do
              %{name: name, type: :regular, size: 0, items: 1, children: nil, flag: "H"}
            else
              Process.put({__MODULE__, :seen}, MapSet.put(seen, key))
              %{name: name, type: :regular, size: size, items: 1, children: nil, flag: " "}
            end

          type == :regular ->
            %{name: name, type: :regular, size: size, items: 1, children: nil, flag: " "}

          true ->
            %{name: name, type: type, size: if(type == :symlink, do: size, else: 0), items: 1, children: nil, flag: "@"}
        end

      {:error, _} ->
        %{name: name, type: :unknown, size: 0, items: 1, children: nil, flag: "!"}
    end
  end

  @doc "Children sorted by `:size`, `:name` or `:items`, `:asc` or `:desc` (directories first by name)."
  def sort(children, by, dir) do
    key =
      case by do
        :size -> &{&1.size, &1.name}
        :items -> &{&1.items, &1.name}
        :name -> &{&1.type != :directory, String.downcase(&1.name)}
      end

    sorted = Enum.sort_by(children, key)
    if dir == :desc, do: Enum.reverse(sorted), else: sorted
  end

  # -- the browser -------------------------------------------------------------------------------

  @doc "A browser over the scan `tree` of `root` (the directory's full path)."
  def new(tree, root) do
    %{tree: tree, root: root, path: [], sel: 0, top: 0, sort: {:size, :desc}, graph: :graph, confirm: nil, msg: nil, help: false, info: false, quit: false, rescan: nil}
  end

  @doc "The directory being shown (a node of the tree)."
  def dir(st), do: Enum.reduce(st.path, st.tree, fn name, n -> Enum.find(n.children, &(&1.name == name)) end)

  # (sort's first press: largest first by size or count, a to z by name)
  defp entries(st) do
    {by, d} = st.sort
    sort(dir(st).children || [], by, if(by == :name, do: flip(d), else: d))
  end

  # What the list shows: inside a directory, ".." (up a level) first.
  @parent %{name: "..", type: :parent, size: 0, items: 0, children: nil, flag: " "}

  defp listing(%{path: []} = st), do: entries(st)
  defp listing(st), do: [@parent | entries(st)]

  # The first real entry's place in the list (after "..").
  defp first(%{path: []}), do: 0
  defp first(st), do: if(entries(st) == [], do: 0, else: 1)

  defp flip(:asc), do: :desc
  defp flip(:desc), do: :asc

  @doc "The full path of the directory shown."
  def dir_path(st), do: Path.join([st.root | st.path])

  @doc "A key pressed: the new state (`quit: true` to leave, `rescan:` a path to scan again)."
  def key(%{confirm: name} = st, k) when name != nil do
    if k in ["y", "Y"], do: delete(%{st | confirm: nil}, name), else: %{st | confirm: nil, msg: "Not deleted"}
  end

  def key(%{help: true} = st, _k), do: %{st | help: false}
  def key(%{info: true} = st, k) when k in ["i", "q", "ESC"], do: %{st | info: false}

  def key(st, k) do
    st = %{st | msg: nil, info: false}
    n = length(listing(st))

    case k do
      k when k in ["j", "<down>", "C-n"] -> move(st, 1, n)
      k when k in ["k", "<up>", "C-p"] -> move(st, -1, n)
      k when k in ["<next>", "C-f", "C-d", "SPC"] -> move(st, 10, n)
      k when k in ["<prior>", "C-b", "C-u"] -> move(st, -10, n)
      k when k in ["<home>", "g g"] -> %{st | sel: 0}
      k when k in ["G", "<end>"] -> %{st | sel: max(n - 1, 0)}
      k when k in ["l", "<right>", "RET"] -> enter(st)
      k when k in ["h", "<left>", "DEL", "<", "C-h"] -> up(st)
      "s" -> sort_by(st, :size)
      "n" -> sort_by(st, :name)
      "C" -> sort_by(st, :items)
      "g" -> %{st | graph: next_graph(st.graph)}
      "d" -> ask_delete(st)
      "r" -> %{st | rescan: dir_path(st)}
      "i" -> if(entry(st), do: %{st | info: true}, else: st)
      "?" -> %{st | help: true}
      k when k in ["q", "C-c", "ESC"] -> %{st | quit: true}
      _ -> st
    end
  end

  defp move(st, d, n), do: %{st | sel: (st.sel + d) |> min(n - 1) |> max(0)}

  defp selected(st), do: Enum.at(listing(st), st.sel)

  # The selection, unless it's "..".
  defp entry(st) do
    case selected(st) do
      %{type: :parent} -> nil
      e -> e
    end
  end

  defp enter(st) do
    case selected(st) do
      %{type: :parent} -> up(st)
      %{type: :directory, flag: f, name: name} when f not in ["<", "!"] -> st = %{st | path: st.path ++ [name], sel: 0, top: 0}; %{st | sel: first(st)}
      %{type: :directory} -> %{st | msg: "Not scanned (another file system, or the kernel's)"}
      _ -> st
    end
  end

  defp up(%{path: []} = st), do: st

  defp up(st) do
    name = List.last(st.path)
    st = %{st | path: Enum.drop(st.path, -1), top: 0}
    %{st | sel: Enum.find_index(listing(st), &(&1.name == name and &1.type != :parent)) || 0}
  end

  # The same key again turns the order around.
  defp sort_by(st, by) do
    sort =
      case st.sort do
        {^by, :desc} -> {by, :asc}
        {^by, :asc} -> {by, :desc}
        _ -> {by, :desc}
      end

    %{st | sort: sort, sel: first(st), top: 0}
  end

  defp next_graph(:graph), do: :percent
  defp next_graph(:percent), do: :both
  defp next_graph(:both), do: :none
  defp next_graph(:none), do: :graph

  defp ask_delete(st) do
    case entry(st) do
      nil -> st
      e -> %{st | confirm: e.name}
    end
  end

  defp delete(st, name) do
    path = Path.join(dir_path(st), name)

    case File.rm_rf(path) do
      {:ok, _} ->
        st = %{st | tree: remove(st.tree, st.path, name), msg: "Deleted #{name}"}
        %{st | sel: min(st.sel, max(length(listing(st)) - 1, 0))}

      {:error, reason, file} ->
        %{st | msg: "Can't delete #{Path.relative_to(file, dir_path(st))}: #{:file.format_error(reason)}"}
    end
  end

  # The tree without `name` in the directory at `path`, sizes and counts above it updated.
  defp remove(node, [], name) do
    gone = Enum.find(node.children, &(&1.name == name))
    children = List.delete(node.children, gone)
    %{node | children: children, size: node.size - gone.size, items: node.items - gone.items, flag: if(children == [], do: "e", else: node.flag)}
  end

  defp remove(node, [step | rest], name) do
    {before, [child | later]} = Enum.split_while(node.children, &(&1.name != step))
    new = remove(child, rest, name)
    %{node | children: before ++ [new | later], size: node.size - child.size + new.size, items: node.items - child.items + new.items}
  end

  @doc "Replace the directory shown with a new scan of it (after `r`)."
  def replace_dir(st, fresh) do
    tree = put_dir(st.tree, st.path, %{fresh | name: dir(st).name})
    st = %{st | tree: tree, rescan: nil, sel: 0, top: 0}
    %{st | sel: first(st)}
  end

  defp put_dir(_node, [], fresh), do: fresh

  defp put_dir(node, [step | rest], fresh) do
    {before, [child | later]} = Enum.split_while(node.children, &(&1.name != step))
    new = put_dir(child, rest, fresh)
    %{node | children: before ++ [new | later], size: node.size - child.size + new.size, items: node.items - child.items + new.items}
  end

  # -- drawing ---------------------------------------------------------------------------------

  @doc "The screen: `rows` lines of `cols` characters, and the state (scrolled to show the selection)."
  def render(st, rows, cols) do
    list_rows = max(rows - 3, 1)
    top = cond do
      st.sel < st.top -> st.sel
      st.sel >= st.top + list_rows -> st.sel - list_rows + 1
      true -> st.top
    end

    st = %{st | top: top}
    d = dir(st)
    all = entries(st)
    largest = all |> Enum.map(& &1.size) |> Enum.max(fn -> 0 end)
    shown = listing(st)

    head = inverse(fit(" ncdu (Lepton) ~ arrows or hjkl to move, ? for help, q to quit", cols))
    title = fit("--- #{dir_path(st)} " <> String.duplicate("-", cols), cols)

    lines =
      shown
      |> Enum.drop(top)
      |> Enum.take(list_rows)
      |> Enum.with_index(top)
      |> Enum.map(fn {e, i} -> line = fit(entry_line(e, d.size, largest, st.graph), cols); if i == st.sel, do: inverse(line), else: line end)

    body = (lines ++ List.duplicate("", list_rows)) |> Enum.take(list_rows)

    footer =
      cond do
        st.confirm -> "Delete #{st.confirm}#{if Enum.find(all, &(&1.name == st.confirm)).type == :directory, do: " and everything in it", else: ""}? (y/N)"
        st.msg -> st.msg
        true -> " Total size: #{human(d.size)}   Items: #{d.items}   Sorted by #{elem(st.sort, 0)} (#{elem(st.sort, 1)})"
      end

    screen = [head, title | body] ++ [inverse(fit(footer, cols))]
    screen = if st.help, do: overlay(screen, help_lines(), cols), else: screen
    screen = if st.info, do: overlay(screen, info_lines(st), cols), else: screen
    {screen, st}
  end

  # "..": blank where the size and bar would be, the name where names are.
  defp entry_line(%{type: :parent}, _total, _largest, graph) do
    blank = entry_line(%{@parent | type: :regular, name: ""}, 0, 0, graph)
    String.duplicate(" ", String.length(blank)) <> ".."
  end

  defp entry_line(e, total, largest, graph) do
    pct = if total > 0, do: e.size * 100 / total, else: 0.0
    bar = if largest > 0, do: round(e.size * 10 / largest), else: 0
    bar = "[" <> String.duplicate("#", bar) <> String.duplicate(" ", 10 - bar) <> "]"
    pct_s = :io_lib.format("~5.1f%", [pct]) |> to_string()

    mid =
      case graph do
        :graph -> bar
        :percent -> "[#{pct_s}]"
        :both -> "[#{pct_s} #{String.slice(bar, 1, 10)}]"
        :none -> ""
      end

    name = e.name <> if(e.type == :directory, do: "/", else: "")
    "#{e.flag}#{String.pad_leading(human(e.size), 10)} #{mid} #{name}"
  end

  defp help_lines do
    [
      "ncdu: keys",
      "",
      "  up/down j/k     move          PgUp/PgDn  a page",
      "  right/l/Enter   open directory",
      "  left/h/Bksp     back up (or Enter on ..)",
      "  s n C           sort by size, name, items (again: reverse)",
      "  g               bars, percentages, both, neither",
      "  d               delete (asks first)",
      "  r               scan this directory again",
      "  i               about the selection",
      "  q               quit",
      "",
      "  Flags:  ! unreadable  . something unreadable inside",
      "          < not scanned (another or the kernel's file system)",
      "          @ link or special file   e empty   H hard link counted elsewhere",
      "",
      "  Any key closes this."
    ]
  end

  defp info_lines(st) do
    e = entry(st)
    type = case e.type do
      :directory -> "directory"
      :regular -> "file"
      :symlink -> "symbolic link"
      other -> to_string(other)
    end

    ["About #{e.name}", "", "  Path:   #{Path.join(dir_path(st), e.name)}", "  Type:   #{type}", "  Size:   #{human(e.size)} (#{e.size} bytes)", "  Items:  #{e.items}", "", "  i closes this."]
  end

  # A box in the middle of the screen.
  defp overlay(screen, box, cols) do
    w = min(Enum.max(Enum.map(box, &String.length/1)) + 4, cols)
    left = max(div(cols - w, 2), 0)
    first = max(div(length(screen) - length(box) - 2, 2), 0)
    framed = ["+" <> String.duplicate("-", w - 2) <> "+"] ++ Enum.map(box, &("| " <> String.pad_trailing(String.slice(&1, 0, w - 4), w - 4) <> " |")) ++ ["+" <> String.duplicate("-", w - 2) <> "+"]

    Enum.with_index(screen)
    |> Enum.map(fn {line, i} ->
      case Enum.at(framed, i - first) do
        nil -> line
        _ when i < first -> line
        b -> String.duplicate(" ", left) <> b
      end
    end)
  end

  defp fit(s, cols), do: s |> String.slice(0, cols) |> String.pad_trailing(cols)
  defp inverse(s), do: "\e[7m" <> s <> "\e[0m"

  @doc "A size as ncdu shows it: B, KiB, MiB, GiB."
  def human(n) when n < 1024, do: "#{n} B"
  def human(n) when n < 1024 * 1024, do: :io_lib.format("~.1f KiB", [n / 1024]) |> to_string()
  def human(n) when n < 1024 * 1024 * 1024, do: :io_lib.format("~.1f MiB", [n / 1024 / 1024]) |> to_string()
  def human(n), do: :io_lib.format("~.1f GiB", [n / 1024 / 1024 / 1024]) |> to_string()

  # -- on the terminal -----------------------------------------------------------------------------

  @doc "Scan `path` (showing progress) and browse it on the terminal; or print it, without one."
  def run(ctx, path, opts) do
    tty = ctx.tty

    if tty && is_pid(tty) && Process.alive?(tty) do
      progress = fn n, p -> TTY.write(tty, "\r\e[2KScanning... #{n} items: #{String.slice(p, -60, 60)}") end
      tree = scan(path, Keyword.put(opts, :progress, progress))
      TTY.write(tty, "\r\e[2K")
      TTY.set_mode(tty, :raw)
      TTY.write(tty, "\e[?1049h\e[?25l")

      try do
        loop(ctx, new(tree, Path.expand(path)), opts)
      after
        TTY.write(tty, "\e[0m\e[?25h\e[?1049l")
        TTY.set_mode(tty, :cooked)
      end
    else
      tree = scan(path, opts)
      for e <- tree.children || [], do: Lepton.IO.puts(ctx, "#{String.pad_leading(human(e.size), 10)}  #{e.name}#{if e.type == :directory, do: "/", else: ""}")
      Lepton.IO.puts(ctx, "#{String.pad_leading(human(tree.size), 10)}  total, #{tree.items} items")
    end

    0
  end

  defp loop(ctx, st, opts) do
    {rows, cols} = TTY.size(ctx.tty)
    {screen, st} = render(st, rows, cols)
    TTY.write(ctx.tty, ["\e[H", Enum.join(screen, "\r\n")])

    case TTY.read_key(ctx.tty) do
      {:resize, _, _} -> loop(ctx, st, opts)
      {:cpr, _, _} -> loop(ctx, st, opts)
      key when is_binary(key) ->
        st = key(st, key)

        cond do
          st.quit -> :ok
          st.rescan -> loop(ctx, replace_dir(st, scan(st.rescan, opts)), opts)
          true -> loop(ctx, st, opts)
        end

      _ ->
        loop(ctx, st, opts)
    end
  end
end
