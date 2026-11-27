defmodule Lepton.FileBrowser do
  @moduledoc """
  The folder view of the Media Player (`play`) and SNES (`snes`): the
  folders and the files it can open in one folder, `..` first. Enter (or
  a double click) opens a folder or a file, Backspace goes up, a click
  selects, the wheel moves; `/` finds a file anywhere below with
  `Lepton.Fzf`, typing parts of its path. `q` quits.
  """

  alias Lepton.{Ctx, Fzf, ListMouse, TTY}

  @doc """
  Browse from `dir` on the terminal. Options:

    * `:title` - the name at the top;
    * `:entries` - `fn dir -> [{:dir, name} | {:file, name}]`, what a folder shows;
    * `:only` - `fn name -> bool`, the files `/` finds;
    * `:open` - `fn dir, paths -> message | nil`: the file chosen first
      (and the ones after it in its folder, or those marked in `/`);
    * `:multi` - whether `/` can mark several (Tab);
    * `:foot`, `:empty` - the keys line, and what an empty folder says.
  """
  def run(ctx, dir, opts) do
    tty = ctx.tty
    TTY.set_mode(tty, :raw)
    TTY.write(tty, "\e[?1049h\e[?25l" <> ListMouse.on())

    try do
      browse(ctx, tty, %{dir: dir, sel: 0, top: 0, message: nil, last: nil}, Map.new(opts))
    after
      TTY.write(tty, ListMouse.off() <> "\e[0m\e[?25h\e[?1049l")
      TTY.set_mode(tty, :cooked)
    end
  end

  @doc false
  def list(dir, opts), do: [{:dir, ".."} | opts.entries.(dir)]

  defp browse(ctx, tty, st, opts) do
    {rows, cols} = TTY.size(tty)
    list = list(st.dir, opts)
    n = length(list)
    sel = st.sel |> max(0) |> min(n - 1)
    height = max(rows - 4, 1)
    st = %{st | sel: sel, top: ListMouse.top(sel, st.top, height)}

    head = "\e[1m #{opts.title}\e[0m  #{Ctx.tildify(ctx, st.dir)}"

    body =
      for {{kind, name}, i} <- list |> Enum.with_index() |> Enum.slice(st.top, height) do
        label = (if kind == :dir, do: name <> "/", else: name) |> String.slice(0, cols - 3)
        if i == sel, do: "\e[7m #{String.pad_trailing(label, cols - 2)}\e[0m", else: " #{label}"
      end

    none = if n == 1 && opts[:empty], do: ["", " " <> opts.empty], else: []
    foot = st.message || opts[:foot] || "Enter: open   /: find   Backspace: up   q: quit"
    screen = [head, "" | body ++ none] ++ List.duplicate("", max(height - length(body) - length(none), 0)) ++ ["\e[2m" <> String.slice(foot, 0, cols) <> "\e[0m"]
    TTY.write(tty, ["\e[H\e[2J", Enum.join(screen, "\r\n")])

    st = %{st | message: nil}
    view = %{first: 2, height: height, top: st.top, n: n}

    case TTY.read_key(tty) do
      k when k in ["q", "ESC", "C-c"] -> 0
      k when k in ["<down>", "j", "C-n"] -> browse(ctx, tty, %{st | sel: sel + 1}, opts)
      k when k in ["<up>", "k", "C-p"] -> browse(ctx, tty, %{st | sel: sel - 1}, opts)
      k when k in ["<next>", "C-v"] -> browse(ctx, tty, %{st | sel: sel + height}, opts)
      k when k in ["<prior>", "M-v"] -> browse(ctx, tty, %{st | sel: sel - height}, opts)
      k when k in ["<home>", "g"] -> browse(ctx, tty, %{st | sel: 0}, opts)
      k when k in ["<end>", "G"] -> browse(ctx, tty, %{st | sel: n - 1}, opts)
      k when k in ["DEL", "h", "<left>"] -> browse(ctx, tty, up(st, opts), opts)
      k when k in ["RET", "l", "<right>"] -> open(ctx, tty, st, list, sel, opts)
      k when k in ["/", "C-t"] -> find(ctx, tty, st, opts)
      {:mouse, _, _, _, _, _} = m ->
        case ListMouse.action(m, view, st.last) do
          {:select, i, last} -> browse(ctx, tty, %{st | sel: i, last: last}, opts)
          {:open, i} -> open(ctx, tty, %{st | sel: i, last: nil}, list, i, opts)
          {:move, d} -> browse(ctx, tty, %{st | sel: sel + d}, opts)
          :none -> browse(ctx, tty, st, opts)
        end

      _ -> browse(ctx, tty, st, opts)
    end
  end

  # Up a folder, the one left selected.
  defp up(st, opts) do
    parent = Path.dirname(st.dir)
    i = Enum.find_index(list(parent, opts), &(&1 == {:dir, Path.basename(st.dir)})) || 0
    %{st | dir: parent, sel: i, top: 0, last: nil, message: nil}
  end

  defp open(ctx, tty, st, list, sel, opts) do
    case Enum.at(list, sel) do
      {:dir, ".."} -> browse(ctx, tty, up(st, opts), opts)
      {:dir, d} -> browse(ctx, tty, %{st | dir: Path.join(st.dir, d), sel: 0, top: 0, last: nil}, opts)
      {:file, _} ->
        files = for {:file, f} <- Enum.drop(list, sel), do: Path.join(st.dir, f)
        message = opts.open.(st.dir, files)
        TTY.write(tty, "\e[?25l" <> ListMouse.on())
        browse(ctx, tty, %{st | message: message}, opts)
    end
  end

  # `/`: a file anywhere below, by parts of its path; it opens as Enter
  # would in its folder (the ones marked with Tab, just those).
  defp find(ctx, tty, st, opts) do
    walk = [hidden: false, only: opts[:only]]

    case Fzf.select(ctx, {:walk, st.dir, walk}, screen: :shared, multi: opts[:multi] == true, prompt: "Find: ", header: "Type parts of a name; Enter opens#{if opts[:multi], do: ", Tab marks several", else: ""}, Esc goes back") do
      {:ok, [one], _} ->
        path = Path.join(st.dir, one)
        dir = Path.dirname(path)
        list = list(dir, opts)
        i = Enum.find_index(list, &(&1 == {:file, Path.basename(path)})) || 0
        open(ctx, tty, %{st | dir: dir, sel: i, top: 0, last: nil}, list, i, opts)

      {:ok, many, _} ->
        paths = Enum.map(many, &Path.join(st.dir, &1))
        message = opts.open.(st.dir, paths)
        TTY.write(tty, "\e[?25l" <> ListMouse.on())
        browse(ctx, tty, %{st | message: message}, opts)

      _ ->
        browse(ctx, tty, st, opts)
    end
  end
end
