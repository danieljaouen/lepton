defmodule Lepton.Commands.Core do
  @moduledoc "File and directory utilities."

  use Lepton.Command
  import Bitwise

  # -- echo / printf / true / false ------------------------------------------------

  defcmd "echo", "display a line of text", usage: "echo [-n] [-e] [STRING...]" do
    {flags, words} = Enum.split_while(args, &(&1 in ["-n", "-e", "-ne", "-en", "-E"]))
    text = Enum.join(words, " ")
    text = if Enum.any?(flags, &String.contains?(&1, "e")), do: unescape(text), else: text
    newline = if Enum.any?(flags, &String.contains?(&1, "n")), do: "", else: "\n"
    IO.write(ctx, text <> newline)
    0
  end

  defcmd "printf", "format and print data", usage: "printf FORMAT [ARG...]" do
    case args do
      [] ->
        IO.err(ctx, "printf: usage: printf FORMAT [ARG...]")
        1

      [fmt | rest] ->
        IO.write(ctx, printf(unescape(fmt), rest))
        0
    end
  end

  defcmd "true", "do nothing, successfully", do: 0
  defcmd "false", "do nothing, unsuccessfully", do: 1

  defcmd "yes", "output a string repeatedly until killed" do
    line = if args == [], do: "y\n", else: Enum.join(args, " ") <> "\n"
    chunk = String.duplicate(line, 256)
    Stream.repeatedly(fn -> IO.write(ctx, chunk) end) |> Stream.run()
    0
  end

  # -- ls ------------------------------------------------------------------------------

  defcmd "ls", "list directory contents", usage: "ls [-1aAlhRrtSdF] [FILE...]" do
    {opts, paths} = getopt(args, "1aAlhRrtSdFG")
    paths = if paths == [], do: ["."], else: paths
    color? = (Lepton.Style.color?(ctx) && Lepton.TTY.tty?(ctx.stdout)) || opts["G"] == true
    colors = lscolors(ctx)

    {files, dirs} =
      Enum.reduce(paths, {[], []}, fn p, {files, dirs} ->
        full = Ctx.path(ctx, p)

        case File.lstat(full) do
          {:ok, %{type: :directory}} -> if opts["d"], do: {files ++ [{p, full}], dirs}, else: {files, dirs ++ [{p, full}]}
          {:ok, _} -> {files ++ [{p, full}], dirs}
          {:error, _} ->
            IO.err(ctx, "ls: cannot access '#{p}': No such file or directory")
            {files, dirs}
        end
      end)

    if files != [], do: print_entries(ctx, files, opts, colors, color?)
    multiple = length(dirs) + length(files) > 1 || opts["R"]

    dirs
    |> Enum.with_index()
    |> Enum.each(fn {{p, full}, i} -> list_dir(ctx, p, full, opts, colors, color?, multiple, i > 0 or files != []) end)

    if length(files) + length(dirs) < length(paths), do: 2, else: 0
  end

  defp list_dir(ctx, label, full, opts, colors, color?, header?, gap?) do
    if gap?, do: IO.write(ctx, "\n")
    if header?, do: IO.puts(ctx, "#{label}:")

    case File.ls(full) do
      {:ok, names} ->
        names =
          cond do
            opts["a"] -> [".", ".." | names]
            opts["A"] -> names
            true -> Enum.reject(names, &String.starts_with?(&1, "."))
          end

        entries = Enum.map(names, &{&1, Path.join(full, &1)})
        print_entries(ctx, entries, opts, colors, color?)

        if opts["R"] do
          for {name, path} <- entries, name not in [".", ".."], File.dir?(path) and not symlink?(path) do
            list_dir(ctx, Path.join(label, name), path, opts, colors, color?, true, true)
          end
        end

      {:error, reason} ->
        IO.err(ctx, "ls: cannot open directory '#{label}': #{:file.format_error(reason)}")
    end
  end

  defp symlink?(path), do: match?({:ok, %{type: :symlink}}, File.lstat(path))

  defp print_entries(ctx, entries, opts, colors, color?) do
    stats = Enum.map(entries, fn {name, path} -> {name, path, stat(path)} end)

    sorted =
      cond do
        opts["t"] -> Enum.sort_by(stats, fn {_, _, s} -> s && s.mtime end, :desc)
        opts["S"] -> Enum.sort_by(stats, fn {_, _, s} -> s && s.size end, :desc)
        true -> Enum.sort_by(stats, fn {n, _, _} -> String.downcase(n) end)
      end

    sorted = if opts["r"], do: Enum.reverse(sorted), else: sorted

    if opts["l"] do
      total = stats |> Enum.map(fn {_, _, s} -> if s, do: div(s.size + 1023, 1024), else: 0 end) |> Enum.sum()
      IO.puts(ctx, "total #{total}")

      size_w = sorted |> Enum.map(fn {_, _, s} -> String.length(fmt_size(s, opts)) end) |> Enum.max(fn -> 1 end)

      for {name, path, s} <- sorted, s do
        link = if s.type == :symlink, do: " -> " <> (case File.read_link(path) do
          {:ok, t} -> t
          _ -> "?"
        end), else: ""

        IO.puts(ctx, [
          mode_string(s), " ", String.pad_leading(to_string(s.links), 2), " root root ",
          String.pad_leading(fmt_size(s, opts), size_w), " ", fmt_time(s.mtime), " ",
          colorize(name, s, colors, color?), classify(s, opts), link
        ])
      end
    else
      names = Enum.map(sorted, fn {name, _path, s} -> {name, s} end)
      tty? = Lepton.TTY.tty?(ctx.stdout)

      if opts["1"] || not tty? do
        for {name, s} <- names, do: IO.puts(ctx, [colorize(name, s, colors, color?), classify(s, opts)])
      else
        columns(ctx, names, opts, colors, color?)
      end
    end
  end

  defp columns(_ctx, [], _opts, _colors, _c), do: :ok

  defp columns(ctx, names, opts, colors, color?) do
    {_, width} = Lepton.TTY.size(ctx.stdout)
    w = (names |> Enum.map(fn {n, _} -> String.length(n) end) |> Enum.max()) + 3
    per_row = max(div(width, w), 1)
    rows = div(length(names) + per_row - 1, per_row)
    grid = Enum.chunk_every(names, rows)

    for r <- 0..(rows - 1) do
      line =
        for col <- grid, entry = Enum.at(col, r), entry != nil do
          {n, s} = entry
          [colorize(n, s, colors, color?), classify(s, opts), String.duplicate(" ", w - String.length(n) - String.length(classify(s, opts)))]
        end

      IO.puts(ctx, String.trim_trailing(Elixir.IO.iodata_to_binary(line)))
    end
  end

  defp stat(path) do
    case File.lstat(path, time: :local) do
      {:ok, s} -> s
      _ -> nil
    end
  end

  defp fmt_size(nil, _), do: "?"
  defp fmt_size(s, %{"h" => true}), do: human(s.size)
  defp fmt_size(s, _), do: to_string(s.size)

  def human(n) when n < 1024, do: to_string(n)
  def human(n) when n < 1024 * 1024, do: :io_lib.format("~.1fK", [n / 1024]) |> to_string()
  def human(n) when n < 1024 * 1024 * 1024, do: :io_lib.format("~.1fM", [n / 1024 / 1024]) |> to_string()
  def human(n), do: :io_lib.format("~.1fG", [n / 1024 / 1024 / 1024]) |> to_string()

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp fmt_time({{_y, m, d}, {hh, mm, _}}) do
    "#{Enum.at(@months, m - 1)} #{String.pad_leading(to_string(d), 2)} #{pad2(hh)}:#{pad2(mm)}"
  end

  defp pad2(n), do: String.pad_leading(to_string(n), 2, "0")

  defp mode_string(s) do
    type = case s.type do
      :directory -> "d"
      :symlink -> "l"
      :device -> "c"
      _ -> "-"
    end

    perms =
      for shift <- [6, 3, 0], into: "" do
        bits = s.mode >>> shift &&& 7
        (if (bits &&& 4) != 0, do: "r", else: "-") <> (if (bits &&& 2) != 0, do: "w", else: "-") <> (if (bits &&& 1) != 0, do: "x", else: "-")
      end

    type <> perms
  end

  defp classify(nil, _), do: ""
  defp classify(s, %{"F" => true}) do
    cond do
      s.type == :directory -> "/"
      s.type == :symlink -> "@"
      (s.mode &&& 0o111) != 0 -> "*"
      true -> ""
    end
  end

  defp classify(_, _), do: ""

  # BSD LSCOLORS (the user's zshrc exports one): 11 fg/bg pairs for
  # dir, symlink, socket, pipe, exec, block, char, setuid, setgid, sticky+ow, ow.
  defp lscolors(ctx) do
    spec = Ctx.get_env(ctx, "LSCOLORS", "exfxcxdxbxegedabagacad")

    spec
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(fn [f, b] -> bsd_color(f, 30) ++ bsd_color(b, 40) end)
    |> then(fn pairs -> %{dir: Enum.at(pairs, 0), link: Enum.at(pairs, 1), exec: Enum.at(pairs, 4), char: Enum.at(pairs, 6)} end)
  end

  defp bsd_color("x", _), do: []

  defp bsd_color(<<c>>, base) when c in ?a..?h, do: [to_string(base + c - ?a)]
  defp bsd_color(<<c>>, base) when c in ?A..?H, do: ["1", to_string(base + c - ?A)]
  defp bsd_color(_, _), do: []

  defp colorize(name, _s, _colors, false), do: name
  defp colorize(name, nil, _colors, _), do: name

  defp colorize(name, s, colors, true) do
    codes =
      cond do
        s.type == :directory -> colors.dir
        s.type == :symlink -> colors.link
        s.type == :device -> colors.char
        (s.mode &&& 0o111) != 0 -> colors.exec
        true -> []
      end

    if codes in [nil, []], do: name, else: "\e[#{Enum.join(codes, ";")}m#{name}\e[0m"
  end

  # -- cat / tac / rev / tee -----------------------------------------------------------------

  defcmd "cat", "concatenate files and print on the standard output", usage: "cat [-n] [FILE...]" do
    {opts, files} = getopt(args, "nA")
    files = if files == [], do: ["-"], else: files

    Enum.reduce(files, {0, 1}, fn f, {status, n} ->
      case open_input(ctx, f) do
        {:ok, dev, close} ->
          n =
            if opts["n"] do
              Enum.reduce(IO.lines(dev), n, fn line, n ->
                IO.write(ctx, String.pad_leading(to_string(n), 6) <> "\t" <> line)
                n + 1
              end)
            else
              copy(dev, ctx.stdout)
              n
            end

          close.()
          {status, n}

        {:error, msg} ->
          IO.err(ctx, "cat: #{msg}")
          {1, n}
      end
    end)
    |> elem(0)
  end

  defcmd "tee", "read from standard input and write to standard output and files", usage: "tee [-a] [FILE...]" do
    {opts, files} = getopt(args, "a")
    mode = if opts["a"], do: :append, else: :write
    devs = for f <- files, {:ok, d} <- [File.open(Ctx.path(ctx, f), [mode, :binary])], do: d

    for line <- IO.lines(ctx) do
      IO.write(ctx, line)
      Enum.each(devs, &IO.write(&1, line))
    end

    Enum.each(devs, &File.close/1)
    0
  end

  @doc "Open a file operand ('-' is stdin). Returns {:ok, dev, close_fun}."
  def open_input(ctx, "-"), do: {:ok, ctx.stdin, fn -> :ok end}

  def open_input(ctx, path) do
    full = Ctx.path(ctx, path)

    cond do
      File.dir?(full) -> {:error, "#{path}: Is a directory"}
      true ->
        case File.open(full, [:read, :binary]) do
          {:ok, dev} -> {:ok, dev, fn -> File.close(dev) end}
          {:error, reason} -> {:error, "#{path}: #{:file.format_error(reason)}"}
        end
    end
  end

  defp copy(from, to) do
    case IO.read_chars(from, 65_536) do
      :eof -> :ok
      data ->
        IO.write(to, data)
        copy(from, to)
    end
  end

  # -- file manipulation -----------------------------------------------------------------

  defcmd "touch", "change file timestamps (creating files)", usage: "touch FILE..." do
    Enum.reduce(args, 0, fn f, status ->
      path = Ctx.path(ctx, f)

      case File.touch(path) do
        :ok -> status
        {:error, r} ->
          IO.err(ctx, "touch: cannot touch '#{f}': #{:file.format_error(r)}")
          1
      end
    end)
  end

  defcmd "mkdir", "make directories", usage: "mkdir [-p] DIR..." do
    {opts, dirs} = getopt(args, "pv")

    Enum.reduce(dirs, 0, fn d, status ->
      path = Ctx.path(ctx, d)
      result = if opts["p"], do: File.mkdir_p(path), else: File.mkdir(path)

      case result do
        :ok ->
          if opts["v"], do: IO.puts(ctx, "mkdir: created directory '#{d}'")
          status

        {:error, r} ->
          IO.err(ctx, "mkdir: cannot create directory '#{d}': #{:file.format_error(r)}")
          1
      end
    end)
  end

  defcmd "rmdir", "remove empty directories", usage: "rmdir DIR..." do
    Enum.reduce(args, 0, fn d, status ->
      case File.rmdir(Ctx.path(ctx, d)) do
        :ok -> status
        {:error, r} ->
          IO.err(ctx, "rmdir: failed to remove '#{d}': #{:file.format_error(r)}")
          1
      end
    end)
  end

  defcmd "rm", "remove files or directories", usage: "rm [-rfv] FILE..." do
    {opts, files} = getopt(args, "rRfvd")

    Enum.reduce(files, 0, fn f, status ->
      path = Ctx.path(ctx, f)

      cond do
        path == "/" ->
          IO.err(ctx, "rm: it is dangerous to operate recursively on '/'")
          1

        not File.exists?(path) and not symlink?(path) ->
          if opts["f"], do: status, else: (IO.err(ctx, "rm: cannot remove '#{f}': No such file || directory"); 1)

        File.dir?(path) && not symlink?(path) && !(opts["r"] || opts["R"]) ->
          IO.err(ctx, "rm: cannot remove '#{f}': Is a directory")
          1

        true ->
          case File.rm_rf(path) do
            {:ok, _} ->
              if opts["v"], do: IO.puts(ctx, "removed '#{f}'")
              status

            {:error, r, _} ->
              IO.err(ctx, "rm: cannot remove '#{f}': #{:file.format_error(r)}")
              1
          end
      end
    end)
  end

  defcmd "cp", "copy files and directories", usage: "cp [-rv] SOURCE... DEST" do
    {opts, operands} = getopt(args, "rRvapf")
    transfer(ctx, "cp", operands, opts, fn src, dst ->
      if File.dir?(src) do
        if opts["r"] || opts["R"] || opts["a"], do: File.cp_r(src, dst) |> norm(), else: {:error, :eisdir}
      else
        File.cp(src, dst)
      end
    end)
  end

  defcmd "mv", "move (rename) files", usage: "mv [-v] SOURCE... DEST" do
    {opts, operands} = getopt(args, "vf")

    transfer(ctx, "mv", operands, opts, fn src, dst ->
      case File.rename(src, dst) do
        {:error, :exdev} -> with :ok <- (File.cp_r(src, dst) |> norm()), {:ok, _} <- File.rm_rf(src), do: :ok
        other -> other
      end
    end)
  end

  defp norm({:ok, _}), do: :ok
  defp norm({:error, r, _}), do: {:error, r}


  defp transfer(ctx, name, operands, opts, fun) when length(operands) >= 2 do
    {sources, [dest]} = Enum.split(operands, -1)
    dest_path = Ctx.path(ctx, dest)
    into_dir? = File.dir?(dest_path)

    if length(sources) > 1 and not into_dir? do
      IO.err(ctx, "#{name}: target '#{dest}' is not a directory")
      1
    else
      Enum.reduce(sources, 0, fn src, status ->
        src_path = Ctx.path(ctx, src)
        target = if into_dir?, do: Path.join(dest_path, Path.basename(src_path)), else: dest_path

        case fun.(src_path, target) do
          :ok ->
            if opts["v"], do: IO.puts(ctx, "'#{src}' -> '#{Ctx.tildify(ctx, target)}'")
            status

          {:error, r} ->
            IO.err(ctx, "#{name}: cannot #{name} '#{src}': #{:file.format_error(r)}")
            1
        end
      end)
    end
  end

  defp transfer(ctx, name, _operands, _opts, _fun) do
    IO.err(ctx, "#{name}: missing destination file operand")
    1
  end

  defcmd "ln", "make links between files", usage: "ln [-s] TARGET LINK" do
    {opts, operands} = getopt(args, "sf")

    case operands do
      [target, link] ->
        link_path = Ctx.path(ctx, link)
        if opts["f"], do: File.rm(link_path)
        result = if opts["s"], do: File.ln_s(target, link_path), else: File.ln(Ctx.path(ctx, target), link_path)

        case result do
          :ok -> 0
          {:error, r} ->
            IO.err(ctx, "ln: #{:file.format_error(r)}")
            1
        end

      _ ->
        IO.err(ctx, "usage: ln [-s] TARGET LINK")
        1
    end
  end

  defcmd "readlink", "print resolved symbolic links", usage: "readlink [-f] FILE" do
    {opts, files} = getopt(args, "f")

    Enum.reduce(files, 0, fn f, status ->
      path = Ctx.path(ctx, f)

      if opts["f"] do
        IO.puts(ctx, resolve(path))
        status
      else
        case File.read_link(path) do
          {:ok, t} -> IO.puts(ctx, t); status
          _ -> 1
        end
      end
    end)
  end

  defp resolve(path, depth \\ 0) do
    case File.read_link(path) do
      {:ok, t} when depth < 40 -> resolve(Path.expand(t, Path.dirname(path)), depth + 1)
      _ -> path
    end
  end

  defcmd "chmod", "change file mode bits", usage: "chmod MODE FILE..." do
    case args do
      [mode | files] when files != [] ->
        Enum.reduce(files, 0, fn f, status ->
          path = Ctx.path(ctx, f)

          with {:ok, st} <- File.stat(path),
               {:ok, new} <- parse_mode(mode, st.mode &&& 0o7777),
               :ok <- File.chmod(path, new) do
            status
          else
            _ ->
              IO.err(ctx, "chmod: cannot change '#{f}'")
              1
          end
        end)

      _ ->
        IO.err(ctx, "usage: chmod MODE FILE...")
        1
    end
  end

  defp parse_mode(mode, current) do
    cond do
      Regex.match?(~r/^[0-7]{3,4}$/, mode) ->
        {:ok, String.to_integer(mode, 8)}

      m = Regex.run(~r/^([ugoa]*)([+\-=])([rwx]+)$/, mode) ->
        [_, who, op, perms] = m
        who = if who in ["", "a"], do: "ugo", else: who
        bits = (if perms =~ "r", do: 4, else: 0) ||| (if perms =~ "w", do: 2, else: 0) ||| (if perms =~ "x", do: 1, else: 0)
        mask = Enum.reduce(String.graphemes(who), 0, fn
          "u", acc -> acc ||| bits <<< 6
          "g", acc -> acc ||| bits <<< 3
          "o", acc -> acc ||| bits
        end)

        {:ok, case op do
          "+" -> current ||| mask
          "-" -> current &&& bnot(mask)
          "=" -> mask
        end}

      true ->
        :error
    end
  end

  defcmd "chown", "change file owner (single-user system: accepted, no-op)", do: 0

  defcmd "stat", "display file status", usage: "stat FILE..." do
    Enum.reduce(args, 0, fn f, status ->
      case File.lstat(Ctx.path(ctx, f), time: :local) do
        {:ok, s} ->
          IO.puts(ctx, "  File: #{f}")
          IO.puts(ctx, "  Size: #{s.size}\tType: #{s.type}\tLinks: #{s.links}")
          IO.puts(ctx, "Access: (#{Integer.to_string(s.mode &&& 0o7777, 8) |> String.pad_leading(4, "0")}/#{mode_string(s)})  Inode: #{s.inode}")
          IO.puts(ctx, "Modify: #{inspect_time(s.mtime)}")
          status

        {:error, r} ->
          IO.err(ctx, "stat: cannot stat '#{f}': #{:file.format_error(r)}")
          1
      end
    end)
  end

  defp inspect_time({{y, mo, d}, {h, mi, s}}), do: "#{y}-#{pad2(mo)}-#{pad2(d)} #{pad2(h)}:#{pad2(mi)}:#{pad2(s)}"

  defcmd "basename", "strip directory and suffix from filenames", usage: "basename NAME [SUFFIX]" do
    case args do
      [name] -> IO.puts(ctx, Path.basename(name)); 0
      [name, suffix] -> IO.puts(ctx, Path.basename(name, suffix)); 0
      _ -> 1
    end
  end

  defcmd "dirname", "strip last component from file name", usage: "dirname NAME" do
    for a <- args, do: IO.puts(ctx, Path.dirname(a))
    0
  end

  defcmd "realpath", "print the resolved absolute file name" do
    for a <- args, do: IO.puts(ctx, resolve(Ctx.path(ctx, a)))
    0
  end

  # -- find / tree / du / df ------------------------------------------------------------------

  defcmd "find", "search for files in a directory hierarchy", usage: "find [PATH...] [-name GLOB] [-type f|d] [-maxdepth N]" do
    {paths, exprs} = Enum.split_while(args, &(not String.starts_with?(&1, "-")))
    paths = if paths == [], do: ["."], else: paths
    filters = parse_find(exprs, %{})

    for p <- paths do
      walk(Ctx.path(ctx, p), p, 0, fn path, shown, depth ->
        if find_match?(path, shown, depth, filters), do: IO.puts(ctx, shown)
      end, filters[:maxdepth])
    end

    0
  end

  defp parse_find(["-name", g | rest], acc), do: parse_find(rest, Map.put(acc, :name, glob_regex(g)))
  defp parse_find(["-iname", g | rest], acc), do: parse_find(rest, Map.put(acc, :name, glob_regex(g, "i")))
  defp parse_find(["-type", t | rest], acc), do: parse_find(rest, Map.put(acc, :type, t))
  defp parse_find(["-maxdepth", n | rest], acc), do: parse_find(rest, Map.put(acc, :maxdepth, String.to_integer(n)))
  defp parse_find(["-mindepth", n | rest], acc), do: parse_find(rest, Map.put(acc, :mindepth, String.to_integer(n)))
  defp parse_find([_ | rest], acc), do: parse_find(rest, acc)
  defp parse_find([], acc), do: acc

  def glob_regex(glob, flags \\ "") do
    re =
      glob
      |> Regex.escape()
      |> String.replace("\\*", ".*")
      |> String.replace("\\?", ".")
      |> String.replace("\\[", "[")
      |> String.replace("\\]", "]")

    Regex.compile!("^" <> re <> "$", flags)
  end

  defp find_match?(path, _shown, depth, f) do
    (f[:name] == nil or Regex.match?(f[:name], Path.basename(path))) and
      (f[:type] == nil or (f[:type] == "d" and File.dir?(path)) or (f[:type] == "f" and File.regular?(path)) or
         (f[:type] == "l" and symlink?(path))) and
      depth >= (f[:mindepth] || 0)
  end

  defp walk(path, shown, depth, fun, maxdepth) do
    fun.(path, shown, depth)

    if File.dir?(path) and not symlink?(path) and (maxdepth == nil or depth < maxdepth) do
      case File.ls(path) do
        {:ok, names} ->
          for n <- Enum.sort(names), do: walk(Path.join(path, n), Path.join(shown, n), depth + 1, fun, maxdepth)

        _ ->
          :ok
      end
    end
  end

  defcmd "tree", "list contents of directories in a tree-like format", usage: "tree [-a] [-L N] [DIR]" do
    {opts, paths} = getopt(args, "aL:d")
    root = List.first(paths) || "."
    IO.puts(ctx, root)
    {d, f} = tree(ctx, Ctx.path(ctx, root), "", opts, 1)
    IO.puts(ctx, "\n#{d} directories" <> if(opts["d"], do: "", else: ", #{f} files"))
    0
  end

  defp tree(ctx, dir, prefix, opts, level) do
    max = Lepton.Args.int(opts, "L", 1000)

    case File.ls(dir) do
      {:ok, names} when level <= max ->
        names = names |> Enum.reject(&(String.starts_with?(&1, ".") && !opts["a"])) |> Enum.sort()
        names = if opts["d"], do: Enum.filter(names, &File.dir?(Path.join(dir, &1))), else: names
        count = length(names)

        names
        |> Enum.with_index(1)
        |> Enum.reduce({0, 0}, fn {name, i}, {d, f} ->
          last = i == count
          path = Path.join(dir, name)
          dir? = File.dir?(path) and not symlink?(path)
          shown = if dir? and Lepton.Style.color?(ctx), do: "\e[1;34m#{name}\e[0m", else: name
          IO.puts(ctx, prefix <> if(last, do: "└── ", else: "├── ") <> shown)

          if dir? do
            {sd, sf} = tree(ctx, path, prefix <> if(last, do: "    ", else: "│   "), opts, level + 1)
            {d + 1 + sd, f + sf}
          else
            {d, f + 1}
          end
        end)

      _ ->
        {0, 0}
    end
  end

  defcmd "du", "estimate file space usage", usage: "du [-sh] [FILE...]" do
    {opts, paths} = getopt(args, "shac")
    paths = if paths == [], do: ["."], else: paths

    for p <- paths do
      total = disk_usage(Ctx.path(ctx, p), p, opts, ctx, 0)
      if opts["s"], do: IO.puts(ctx, "#{fmt_du(total, opts)}\t#{p}")
    end

    0
  end

  defp disk_usage(path, shown, opts, ctx, depth) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        sub =
          case File.ls(path) do
            {:ok, names} -> Enum.map(names, &disk_usage(Path.join(path, &1), Path.join(shown, &1), opts, ctx, depth + 1)) |> Enum.sum()
            _ -> 0
          end

        total = sub + 4096
        unless opts["s"], do: IO.puts(ctx, "#{fmt_du(total, opts)}\t#{shown}")
        total

      {:ok, s} ->
        if opts["a"] && !opts["s"], do: IO.puts(ctx, "#{fmt_du(s.size, opts)}\t#{shown}")
        s.size

      _ ->
        0
    end
  end

  defp fmt_du(bytes, %{"h" => true}), do: human(bytes)
  defp fmt_du(bytes, _), do: to_string(div(bytes + 1023, 1024))

  defcmd "df", "report file system space usage", usage: "df [-h]" do
    {opts, _} = getopt(args, "h")
    IO.puts(ctx, "Filesystem      Size  Used Avail Use% Mounted on")
    mem = Lepton.Sys.meminfo()
    total = Map.get(mem, "MemTotal", 0)
    avail = Map.get(mem, "MemAvailable", 0)

    for m <- Lepton.Sys.mounts(), m.type in ["rootfs", "tmpfs", "ramfs", "devtmpfs", "iso9660", "ext4", "vfat"] do
      {size, used} = if m.type in ["rootfs", "ramfs"], do: {total, total - avail}, else: {total, 0}
      fmt = fn n -> if opts["h"], do: human(n), else: to_string(div(n, 1024)) end
      pct = if size > 0, do: "#{div(used * 100, size)}%", else: "-"
      IO.puts(ctx, Enum.join([String.pad_trailing(m.device, 15), String.pad_leading(fmt.(size), 5), String.pad_leading(fmt.(used), 5), String.pad_leading(fmt.(size - used), 5), String.pad_leading(pct, 4), m.dir], " "))
    end

    0
  end

  # -- misc ---------------------------------------------------------------------------------

  defcmd "seq", "print a sequence of numbers", usage: "seq [FIRST [INCR]] LAST" do
    nums = Enum.map(args, &String.to_integer/1)

    {first, step, last} =
      case nums do
        [l] -> {1, 1, l}
        [f, l] -> {f, 1, l}
        [f, s, l] -> {f, s, l}
        _ -> {1, 1, 0}
      end

    if step != 0 and ((step > 0 and first <= last) or (step < 0 and first >= last)) do
      first |> Stream.iterate(&(&1 + step)) |> Stream.take_while(&(if step > 0, do: &1 <= last, else: &1 >= last)) |> Enum.each(&IO.puts(ctx, to_string(&1)))
    end

    0
  end

  defcmd "test", "check file types and compare values", aliases: ["["] do
    args = if List.last(args) == "]", do: Enum.drop(args, -1), else: args
    if test(args, ctx), do: 0, else: 1
  end

  defp test([], _), do: false
  defp test(["!" | rest], ctx), do: not test(rest, ctx)
  defp test([a, "-a", b | _] = _all, ctx), do: test([a], ctx) and test([b], ctx)
  defp test(["-e", f], ctx), do: File.exists?(Ctx.path(ctx, f))
  defp test(["-f", f], ctx), do: File.regular?(Ctx.path(ctx, f))
  defp test(["-d", f], ctx), do: File.dir?(Ctx.path(ctx, f))
  defp test(["-L", f], ctx), do: symlink?(Ctx.path(ctx, f))
  defp test(["-h", f], ctx), do: symlink?(Ctx.path(ctx, f))
  defp test(["-s", f], ctx), do: match?({:ok, %{size: s}} when s > 0, File.stat(Ctx.path(ctx, f)))
  defp test(["-x", f], ctx), do: match?({:ok, %{mode: m}} when (m &&& 0o111) != 0, File.stat(Ctx.path(ctx, f)))
  defp test(["-r", f], ctx), do: File.exists?(Ctx.path(ctx, f))
  defp test(["-w", f], ctx), do: File.exists?(Ctx.path(ctx, f))
  defp test(["-z", s], _), do: s == ""
  defp test(["-n", s], _), do: s != ""
  defp test([a, "=", b], _), do: a == b
  defp test([a, "==", b], _), do: a == b
  defp test([a, "!=", b], _), do: a != b
  defp test([a, op, b], _) when op in ~w(-eq -ne -lt -le -gt -ge) do
    {x, y} = {String.to_integer(a), String.to_integer(b)}

    case op do
      "-eq" -> x == y
      "-ne" -> x != y
      "-lt" -> x < y
      "-le" -> x <= y
      "-gt" -> x > y
      "-ge" -> x >= y
    end
  end

  defp test([s], _), do: s != ""
  defp test(_, _), do: false

  defcmd "expr", "evaluate expressions" do
    case args do
      [a, op, b] when op in ~w(+ - * / %) ->
        {x, y} = {String.to_integer(a), String.to_integer(b)}
        r = case op do
          "+" -> x + y
          "-" -> x - y
          "*" -> x * y
          "/" -> div(x, y)
          "%" -> rem(x, y)
        end

        IO.puts(ctx, to_string(r))
        if r == 0, do: 1, else: 0

      _ ->
        IO.err(ctx, "expr: syntax error")
        2
    end
  end

  # -- helpers ------------------------------------------------------------------------------

  def unescape(s) do
    s
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\e", "\e")
    |> String.replace("\\033", "\e")
    |> String.replace("\\a", "\a")
    |> String.replace("\\r", "\r")
    |> String.replace("\\\\", "\\")
  end

  defp printf(fmt, args) do
    {out, rest} =
      Regex.split(~r/%[-0-9.]*[sdixfc%]/, fmt, include_captures: true)
      |> Enum.reduce({"", args}, fn piece, {acc, args} ->
        case Regex.run(~r/^%([-0-9.]*)([sdixfc%])$/, piece) do
          [_, _, "%"] -> {acc <> "%", args}
          [_, width, conv] ->
            {arg, rest} = case args do
              [a | r] -> {a, r}
              [] -> {"", []}
            end

            {acc <> pad_printf(convert(conv, arg), width), rest}

          nil -> {acc <> piece, args}
        end
      end)

    if rest != [] and rest != args and String.contains?(fmt, "%"), do: out <> printf(fmt, rest), else: out
  end

  defp convert("s", a), do: a
  defp convert("c", a), do: String.first(a) || ""
  defp convert(c, a) when c in ["d", "i"], do: a |> Integer.parse() |> then(fn {i, _} -> to_string(i); :error -> "0" end)
  defp convert("x", a), do: a |> String.to_integer() |> Integer.to_string(16) |> String.downcase()
  defp convert("f", a), do: a |> Float.parse() |> then(fn {f, _} -> :erlang.float_to_binary(f, decimals: 6); :error -> "0.000000" end)

  defp pad_printf(s, ""), do: s

  defp pad_printf(s, width) do
    case Integer.parse(String.split(width, ".") |> hd()) do
      {w, _} when w < 0 -> String.pad_trailing(s, -w)
      {w, _} -> String.pad_leading(s, w)
      :error -> s
    end
  end
end
