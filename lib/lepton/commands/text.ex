defmodule Lepton.Commands.Text do
  @moduledoc "Text processing utilities."

  use Lepton.Command
  alias Lepton.Commands.Core

  # Iterate the lines of each FILE operand (or stdin).
  defp each_input(ctx, name, files, fun) do
    files = if files == [], do: ["-"], else: files

    Enum.reduce(files, 0, fn f, status ->
      case Core.open_input(ctx, f) do
        {:ok, dev, close} ->
          fun.(f, IO.lines(dev))
          close.()
          status

        {:error, msg} ->
          IO.err(ctx, "#{name}: #{msg}")
          2
      end
    end)
  end

  defp all_lines(ctx, name, files) do
    acc = :ets.new(:lines, [:ordered_set, :private])

    status =
      each_input(ctx, name, files, fn _f, lines ->
        Enum.each(lines, fn l -> :ets.insert(acc, {:ets.info(acc, :size), l}) end)
      end)

    lines = acc |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
    :ets.delete(acc)
    {lines, status}
  end

  defp chomp(l), do: String.trim_trailing(l, "\n")

  # -- grep ------------------------------------------------------------------------------

  defcmd "grep", "print lines that match patterns", usage: "grep [-ivnclrHhoqEFw] PATTERN [FILE...]" do
    {opts, operands} = getopt(args, "ivnclrRHhoqEFwse:")

    {pattern, files} =
      case {opts["e"], operands} do
        {nil, [p | f]} -> {p, f}
        {p, f} -> {p, f}
      end

    if pattern == nil do
      IO.err(ctx, "usage: grep [OPTION...] PATTERN [FILE...]")
      2
    else
      re = grep_regex(pattern, opts)
      recursive = opts["r"] || opts["R"]
      files = if recursive, do: expand_recursive(ctx, if(files == [], do: ["."], else: files)), else: files
      show_name = (length(files) > 1 || recursive) && !opts["h"] || opts["H"]
      matched = :counters.new(1, [])

      status =
        each_input(ctx, "grep", files, fn f, lines ->
          count =
            lines
            |> Stream.with_index(1)
            |> Enum.reduce_while(0, fn {line, n}, count ->
              text = chomp(line)
              hit = Regex.match?(re, text) != (opts["v"] == true)

              cond do
                not hit -> {:cont, count}
                opts["q"] -> {:halt, count + 1}
                opts["l"] -> {:halt, count + 1}
                opts["c"] -> {:cont, count + 1}
                true ->
                  prefix = (if show_name, do: magenta(ctx, f) <> ":", else: "") <> (if opts["n"], do: green(ctx, to_string(n)) <> ":", else: "")

                  if opts["o"] do
                    for [m | _] <- Regex.scan(re, text), do: IO.puts(ctx, prefix <> m)
                  else
                    IO.puts(ctx, prefix <> highlight(ctx, re, text, opts["v"]))
                  end

                  {:cont, count + 1}
              end
            end)

          if count > 0, do: :counters.add(matched, 1, count)
          if opts["l"] && count > 0, do: IO.puts(ctx, f)
          if opts["c"], do: IO.puts(ctx, (if show_name, do: f <> ":", else: "") <> to_string(count))
        end)

      cond do
        status == 2 && opts["s"] -> if :counters.get(matched, 1) > 0, do: 0, else: 1
        status == 2 -> 2
        :counters.get(matched, 1) > 0 -> 0
        true -> 1
      end
    end
  end

  defp grep_regex(pattern, opts) do
    source = if opts["F"], do: Regex.escape(pattern), else: basic_to_extended(pattern, opts["E"])
    source = if opts["w"], do: "\\b(?:" <> source <> ")\\b", else: source
    Regex.compile!(source, if(opts["i"], do: "iu", else: "u"))
  end

  # BRE: \| \( \) \+ \? are operators, bare ( ) | + ? are literals.
  defp basic_to_extended(p, true), do: p

  defp basic_to_extended(p, _) do
    p
    |> String.replace(~r/\\([|()+?{}])|([|()+?{}])/, fn
      "\\" <> op -> op
      lit -> "\\" <> lit
    end)
  end

  defp highlight(ctx, re, text, invert) do
    if Lepton.Style.color?(ctx) && !invert && Lepton.TTY.tty?(ctx.stdout) do
      Regex.replace(re, text, fn m -> "\e[1;31m" <> m <> "\e[0m" end)
    else
      text
    end
  end

  defp magenta(ctx, s), do: if(Lepton.Style.color?(ctx) and Lepton.TTY.tty?(ctx.stdout), do: "\e[35m#{s}\e[0m", else: s)
  defp green(ctx, s), do: if(Lepton.Style.color?(ctx) and Lepton.TTY.tty?(ctx.stdout), do: "\e[32m#{s}\e[0m", else: s)

  defp expand_recursive(ctx, paths) do
    Enum.flat_map(paths, fn p ->
      full = Ctx.path(ctx, p)

      if File.dir?(full) do
        Path.wildcard(Path.join(full, "**/*"))
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&String.contains?(&1, "/.git/"))
        |> Enum.map(&Path.join(p, Path.relative_to(&1, full)))
      else
        [p]
      end
    end)
  end

  # -- head / tail -------------------------------------------------------------------------

  defcmd "head", "output the first part of files", usage: "head [-n N] [FILE...]" do
    {opts, files} = getopt(args, "n:c:q")
    n = Lepton.Args.int(opts, "n", Lepton.Args.int(opts, "#", 10))
    multi = length(files) > 1

    each_input(ctx, "head", files, fn f, lines ->
      if multi, do: IO.puts(ctx, "==> #{f} <==")
      lines |> Stream.take(n) |> Enum.each(&IO.write(ctx, &1))
    end)
  end

  defcmd "tail", "output the last part of files", usage: "tail [-n N] [-f] [FILE...]" do
    {opts, files} = getopt(args, "n:fq")
    spec = Map.get(opts, "n", Map.get(opts, "#", "10"))

    each_input(ctx, "tail", files, fn f, lines ->
      if String.starts_with?(spec, "+") do
        start = String.to_integer(String.trim_leading(spec, "+"))
        lines |> Stream.drop(start - 1) |> Enum.each(&IO.write(ctx, &1))
      else
        n = String.to_integer(spec)
        {q, _} = Enum.reduce(lines, {:queue.new(), 0}, fn l, {q, size} ->
          q = :queue.in(l, q)
          if size >= n, do: {elem(:queue.out(q), 1), size}, else: {q, size + 1}
        end)

        q |> :queue.to_list() |> Enum.each(&IO.write(ctx, &1))
      end

      if opts["f"] && f != "-", do: follow(ctx, Ctx.path(ctx, f))
    end)
  end

  defp follow(ctx, path) do
    size = case File.stat(path) do
      {:ok, s} -> s.size
      _ -> 0
    end

    follow(ctx, path, size)
  end

  defp follow(ctx, path, pos) do
    Process.sleep(500)

    case File.stat(path) do
      {:ok, %{size: size}} when size > pos ->
        {:ok, fd} = :file.open(path, [:read, :binary, :raw])
        {:ok, data} = :file.pread(fd, pos, size - pos)
        :file.close(fd)
        IO.write(ctx, data)
        follow(ctx, path, size)

      _ ->
        follow(ctx, path, pos)
    end
  end

  # -- wc / sort / uniq / cut / tr / rev / tac / nl -------------------------------------------

  defcmd "wc", "print newline, word, and byte counts", usage: "wc [-lwcm] [FILE...]" do
    {opts, files} = getopt(args, "lwcm")
    which = if Enum.any?(~w(l w c m), &opts[&1]), do: opts, else: %{"l" => true, "w" => true, "c" => true}

    totals =
      Enum.map(if(files == [], do: ["-"], else: files), fn f ->
        counts =
          case Core.open_input(ctx, f) do
            {:ok, dev, close} ->
              c = Enum.reduce(IO.lines(dev), {0, 0, 0, 0}, fn line, {l, w, b, m} ->
                {l + if(String.ends_with?(line, "\n"), do: 1, else: 0), w + length(String.split(line)), b + byte_size(line), m + String.length(line)}
              end)

              close.()
              c

            {:error, msg} ->
              IO.err(ctx, "wc: #{msg}")
              {0, 0, 0, 0}
          end

        print_wc(ctx, counts, which, if(f == "-", do: "", else: f))
        counts
      end)

    if length(totals) > 1 do
      sum = Enum.reduce(totals, {0, 0, 0, 0}, fn {a, b, c, d}, {w, x, y, z} -> {a + w, b + x, c + y, d + z} end)
      print_wc(ctx, sum, which, "total")
    end

    0
  end

  defp print_wc(ctx, {l, w, b, m}, which, name) do
    cols = for {k, v} <- [{"l", l}, {"w", w}, {"c", b}, {"m", m}], which[k], do: String.pad_leading(to_string(v), 7)
    IO.puts(ctx, String.trim_trailing(Enum.join(cols, " ") <> " " <> name))
  end

  defcmd "sort", "sort lines of text files", usage: "sort [-rnuf] [-k N] [-t SEP] [FILE...]" do
    {opts, files} = getopt(args, "rnufk:t:")
    {lines, status} = all_lines(ctx, "sort", files)
    lines = Enum.map(lines, &chomp/1)
    key = fn line -> sort_key(line, opts) end
    sorted = Enum.sort_by(lines, key)
    sorted = if opts["r"], do: Enum.reverse(sorted), else: sorted
    sorted = if opts["u"], do: Enum.uniq_by(sorted, key), else: sorted
    Enum.each(sorted, &IO.puts(ctx, &1))
    status
  end

  defp sort_key(line, opts) do
    field =
      case opts["k"] do
        nil -> line
        k ->
          n = k |> String.split(",") |> hd() |> String.to_integer()
          sep = opts["t"]
          parts = if sep, do: String.split(line, sep), else: String.split(line)
          Enum.at(parts, n - 1, "")
      end

    field = if opts["f"], do: String.downcase(field), else: field

    if opts["n"] do
      case Float.parse(String.trim(field)) do
        {f, _} -> {0, f}
        :error -> {-1, 0.0}
      end
    else
      field
    end
  end

  defcmd "uniq", "report or omit repeated lines", usage: "uniq [-cdu] [FILE]" do
    {opts, files} = getopt(args, "cdui")
    {lines, status} = all_lines(ctx, "uniq", files)
    norm = fn l -> if opts["i"], do: String.downcase(chomp(l)), else: chomp(l) end

    lines
    |> Enum.chunk_by(norm)
    |> Enum.each(fn group ->
      n = length(group)

      cond do
        opts["d"] && n < 2 -> :skip
        opts["u"] && n > 1 -> :skip
        opts["c"] -> IO.puts(ctx, String.pad_leading(to_string(n), 7) <> " " <> chomp(hd(group)))
        true -> IO.puts(ctx, chomp(hd(group)))
      end
    end)

    status
  end

  defcmd "cut", "remove sections from each line", usage: "cut -d DELIM -f FIELDS | -c CHARS [FILE...]" do
    {opts, files} = getopt(args, "d:f:c:s")
    delim = opts["d"] || "\t"

    each_input(ctx, "cut", files, fn _f, lines ->
      for line <- lines do
        text = chomp(line)

        cond do
          spec = opts["f"] ->
            if String.contains?(text, delim) || !opts["s"] do
              fields = String.split(text, delim)
              idx = ranges(spec, length(fields))
              IO.puts(ctx, idx |> Enum.map(&Enum.at(fields, &1 - 1)) |> Enum.reject(&is_nil/1) |> Enum.join(delim))
            end

          spec = opts["c"] ->
            g = String.graphemes(text)
            IO.puts(ctx, ranges(spec, length(g)) |> Enum.map_join(&Enum.at(g, &1 - 1, "")))

          true ->
            IO.puts(ctx, text)
        end
      end
    end)
  end

  defp ranges(spec, max) do
    spec
    |> String.split(",")
    |> Enum.flat_map(fn part ->
      case String.split(part, "-") do
        [n] -> [String.to_integer(n)]
        ["", b] -> Enum.to_list(1..String.to_integer(b))
        [a, ""] -> Enum.to_list(String.to_integer(a)..max(max, String.to_integer(a)))
        [a, b] -> Enum.to_list(String.to_integer(a)..String.to_integer(b))
      end
    end)
  end

  defcmd "tr", "translate or delete characters", usage: "tr [-d] SET1 [SET2]" do
    {opts, sets} = getopt(args, "ds")
    input = IO.read_all(ctx.stdin)

    out =
      case {opts["d"], sets} do
        {true, [set]} ->
          chars = expand_set(set)
          input |> String.graphemes() |> Enum.reject(&(&1 in chars)) |> Enum.join()

        {_, [a, b]} ->
          {from, to} = {expand_set(a), expand_set(b)}
          to = to ++ List.duplicate(List.last(to), max(length(from) - length(to), 0))
          map = Map.new(Enum.zip(from, to))
          translated = input |> String.graphemes() |> Enum.map_join(&Map.get(map, &1, &1))
          if opts["s"], do: Regex.replace(~r/(.)\1+/u, translated, "\\1"), else: translated

        _ ->
          input
      end

    IO.write(ctx, out)
    0
  end

  defp expand_set(set) do
    set = set |> String.replace("[:lower:]", "a-z") |> String.replace("[:upper:]", "A-Z") |> String.replace("[:digit:]", "0-9") |> String.replace("[:space:]", " \t\n")
    set = Core.unescape(set)

    Regex.scan(~r/(.)-(.)|(.)/us, set)
    |> Enum.flat_map(fn
      [_, a, b] ->
        [from] = String.to_charlist(a)
        [to] = String.to_charlist(b)
        for c <- from..to, do: <<c::utf8>>
      [_, "", "", c] -> [c]
    end)
  end

  defcmd "rev", "reverse lines characterwise", usage: "rev [FILE...]" do
    each_input(ctx, "rev", args, fn _f, lines -> Enum.each(lines, &IO.puts(ctx, &1 |> chomp() |> String.reverse())) end)
  end

  defcmd "tac", "concatenate and print files in reverse", usage: "tac [FILE...]" do
    {lines, status} = all_lines(ctx, "tac", args)
    lines |> Enum.reverse() |> Enum.each(&IO.puts(ctx, chomp(&1)))
    status
  end

  defcmd "nl", "number lines of files", usage: "nl [FILE...]" do
    each_input(ctx, "nl", args, fn _f, lines ->
      Enum.reduce(lines, 1, fn l, n ->
        if String.trim(l) == "" do
          IO.write(ctx, l)
          n
        else
          IO.write(ctx, String.pad_leading(to_string(n), 6) <> "\t" <> l)
          n + 1
        end
      end)
    end)
  end

  # -- sed (s///, p, d, line addresses) -----------------------------------------------------

  defcmd "sed", "stream editor (s, d, p commands)", usage: "sed [-n] [-i] [-e] SCRIPT [FILE...]" do
    {opts, operands} = getopt(args, "nie:E")

    {script, files} =
      case {opts["e"], operands} do
        {nil, [s | f]} -> {s, f}
        {s, f} -> {s, f}
      end

    cmds = script |> String.split(~r/;|\n/, trim: true) |> Enum.map(&parse_sed/1)

    if opts["i"] do
      Enum.each(files, fn f ->
        path = Ctx.path(ctx, f)
        text = File.read!(path)
        lines = String.split(text, "\n") |> then(&if(List.last(&1) == "", do: Enum.drop(&1, -1), else: &1))
        out = run_sed(lines, cmds, opts) |> Enum.map_join(&(&1 <> "\n"))
        File.write!(path, out)
      end)

      0
    else
      each_input(ctx, "sed", files, fn _f, lines ->
        lines |> Enum.map(&chomp/1) |> run_sed(cmds, opts) |> Enum.each(&IO.puts(ctx, &1))
      end)
    end
  end

  defp parse_sed(cmd) do
    {addr, rest} =
      case Regex.run(~r/^(\d+|\$|\/[^\/]*\/)?(.*)$/s, String.trim(cmd)) do
        [_, "", rest] -> {nil, rest}
        [_, a, rest] -> {a, rest}
      end

    case rest do
      "s" <> <<sep::utf8, body::binary>> ->
        [pat, rep, flags] =
          case String.split(body, <<sep::utf8>>) do
            [p, r, f | _] -> [p, r, f]
            [p, r] -> [p, r, ""]
          end

        re = Regex.compile!(pat, if(String.contains?(flags, "I"), do: "iu", else: "u"))
        # sed's \1 already matches Elixir's replacement syntax; & is the whole match.
        rep = String.replace(rep, "&", "\\0")
        {addr, {:s, re, rep, String.contains?(flags, "g"), String.contains?(flags, "p")}}

      "d" -> {addr, :d}
      "p" -> {addr, :p}
      "q" -> {addr, :q}
      other -> {addr, {:unknown, other}}
    end
  end

  defp run_sed(lines, cmds, opts) do
    total = length(lines)

    lines
    |> Enum.with_index(1)
    |> Enum.reduce_while([], fn {line, n}, out ->
      {line, out, action} =
        Enum.reduce_while(cmds, {line, out, :print}, fn {addr, cmd}, {line, out, _} ->
          if sed_addr?(addr, line, n, total) do
            case cmd do
              {:s, re, rep, global, p} ->
                new = Regex.replace(re, line, rep, global: global)
                out = if p and new != line, do: [new | out], else: out
                {:cont, {new, out, :print}}

              :d -> {:halt, {line, out, :delete}}
              :p -> {:cont, {line, [line | out], :print}}
              :q -> {:halt, {line, out, :quit}}
              _ -> {:cont, {line, out, :print}}
            end
          else
            {:cont, {line, out, :print}}
          end
        end)

      out = if action in [:print, :quit] && !opts["n"], do: [line | out], else: out
      if action == :quit, do: {:halt, out}, else: {:cont, out}
    end)
    |> Enum.reverse()
  end

  defp sed_addr?(nil, _, _, _), do: true
  defp sed_addr?("$", _, n, total), do: n == total
  defp sed_addr?("/" <> re, line, _, _), do: Regex.match?(Regex.compile!(String.trim_trailing(re, "/")), line)
  defp sed_addr?(num, _, n, _), do: String.to_integer(num) == n

  # -- awk (print fields, -F, simple /regex/ filters, NR, NF) ---------------------------------

  defcmd "awk", "pattern scanning (subset: print fields, -F, /re/, NR, NF)", usage: "awk [-F SEP] 'PROGRAM' [FILE...]" do
    {opts, operands} = getopt(args, "F:")

    case operands do
      [prog | files] ->
        sep = opts["F"]
        {filter, action} = parse_awk(prog)

        each_input(ctx, "awk", files, fn _f, lines ->
          lines
          |> Stream.with_index(1)
          |> Enum.each(fn {line, nr} ->
            text = chomp(line)
            fields = if sep, do: String.split(text, sep), else: String.split(text)

            if filter == nil or Regex.match?(filter, text) do
              IO.puts(ctx, awk_action(action, text, fields, nr))
            end
          end)
        end)

      [] ->
        IO.err(ctx, "usage: awk [-F SEP] 'PROGRAM' [FILE...]")
        2
    end
  end

  defp parse_awk(prog) do
    prog = String.trim(prog)

    {filter, rest} =
      case Regex.run(~r/^\/(.*?)\/\s*(.*)$/s, prog) do
        [_, re, rest] -> {Regex.compile!(re), rest}
        nil -> {nil, prog}
      end

    action =
      case Regex.run(~r/^\{\s*print\s*(.*?)\s*;?\s*\}$/s, String.trim(rest)) do
        [_, ""] -> :line
        [_, expr] -> {:print, String.split(expr, ",") |> Enum.map(&String.trim/1)}
        nil -> :line
      end

    {filter, action}
  end

  defp awk_action(:line, text, _, _), do: text

  defp awk_action({:print, exprs}, text, fields, nr) do
    Enum.map_join(exprs, " ", fn
      "$0" -> text
      "NR" -> to_string(nr)
      "NF" -> to_string(length(fields))
      "$NF" -> List.last(fields) || ""
      "$" <> n -> Enum.at(fields, String.to_integer(n) - 1, "")
      "\"" <> s -> String.trim_trailing(s, "\"")
      other -> other
    end)
  end

  # -- diff ---------------------------------------------------------------------------------

  defcmd "diff", "compare files line by line (unified format)", usage: "diff [-u] FILE1 FILE2" do
    {_opts, files} = getopt(args, "uN")

    case files do
      [a, b] ->
        with {:ok, ta} <- File.read(Ctx.path(ctx, a)), {:ok, tb} <- File.read(Ctx.path(ctx, b)) do
          case Lepton.Diff.unified(ta, tb, a, b) do
            "" -> 0
            text ->
              IO.write(ctx, Lepton.Diff.colorize(text, Lepton.Style.color?(ctx) and Lepton.TTY.tty?(ctx.stdout)))
              1
          end
        else
          {:error, r} ->
            IO.err(ctx, "diff: #{:file.format_error(r)}")
            2
        end

      _ ->
        IO.err(ctx, "usage: diff FILE1 FILE2")
        2
    end
  end

  # -- xargs ---------------------------------------------------------------------------------

  defcmd "xargs", "build and execute command lines from standard input", usage: "xargs [-0] [-n N] [-I STR] [CMD [ARG...]]" do
    {opts, cmd} = getopt(args, "0n:I:")
    cmd = if cmd == [], do: ["echo"], else: cmd
    text = IO.read_all(ctx.stdin)

    # -0: items end in NULs (find -print0), names kept whole whatever is in
    # them; -I: one item a line; else, as GNU xargs, blanks between items
    # and quotes or a backslash to keep one together.
    items =
      cond do
        # (getopt reads -0 as a number, as for head -5)
        opts["0"] || opts["#"] == "0" -> String.split(text, <<0>>, trim: true)
        opts["I"] -> text |> String.split("\n", trim: true) |> Enum.map(&String.trim_leading/1) |> Enum.reject(&(&1 == ""))
        true -> xargs_words(text)
      end

    # (-I runs the command once an item, as GNU xargs does)
    n = if opts["I"], do: 1, else: Lepton.Args.int(opts, "n", 5000)

    items
    |> Enum.chunk_every(max(n, 1))
    |> Enum.reduce(0, fn chunk, status ->
      argv =
        case opts["I"] do
          nil -> cmd ++ chunk
          marker -> Enum.map(cmd, &String.replace(&1, marker, Enum.join(chunk, " ")))
        end

      [name | rest] = argv
      shell = %Lepton.Shell{ctx: ctx}
      max(status, Lepton.Shell.Exec.exec(name, rest, shell))
    end)
  end

  @doc false
  # xargs's items without -0: blanks and newlines between them; 'single' or
  # "double" quotes, or a backslash, put blanks (and the other quote) in one.
  def xargs_words(text), do: xargs_words(text, [], nil, false)

  defp xargs_words(<<>>, acc, cur, _q), do: Enum.reverse(if(cur, do: [cur | acc], else: acc))
  defp xargs_words(<<"\\", c::utf8, rest::binary>>, acc, cur, false), do: xargs_words(rest, acc, (cur || "") <> <<c::utf8>>, false)
  defp xargs_words(<<q, rest::binary>>, acc, cur, false) when q in [?', ?"], do: xargs_words(rest, acc, cur || "", q)
  defp xargs_words(<<q, rest::binary>>, acc, cur, q), do: xargs_words(rest, acc, cur, false)
  defp xargs_words(<<c::utf8, rest::binary>>, acc, cur, q) when q != false, do: xargs_words(rest, acc, cur <> <<c::utf8>>, q)
  defp xargs_words(<<c, rest::binary>>, acc, cur, false) when c in [?\s, ?\t, ?\n, ?\r], do: xargs_words(rest, if(cur, do: [cur | acc], else: acc), nil, false)
  defp xargs_words(<<c::utf8, rest::binary>>, acc, cur, false), do: xargs_words(rest, acc, (cur || "") <> <<c::utf8>>, false)

  # -- checksums / encodings ---------------------------------------------------------------------

  defcmd "md5sum", "compute MD5 message digest", usage: "md5sum [FILE...]", do: digest(ctx, args, "md5sum", :md5)
  defcmd "sha1sum", "compute SHA1 message digest", usage: "sha1sum [FILE...]", do: digest(ctx, args, "sha1sum", :sha)
  defcmd "sha256sum", "compute SHA256 message digest", usage: "sha256sum [FILE...]", do: digest(ctx, args, "sha256sum", :sha256)
  defcmd "sha512sum", "compute SHA512 message digest", usage: "sha512sum [FILE...]", do: digest(ctx, args, "sha512sum", :sha512)

  defp digest(ctx, args, name, algo) do
    files = if args == [], do: ["-"], else: args

    Enum.reduce(files, 0, fn f, status ->
      data = if f == "-", do: {:ok, IO.read_all(ctx.stdin)}, else: File.read(Ctx.path(ctx, f))

      case data do
        {:ok, bin} ->
          IO.puts(ctx, Base.encode16(:crypto.hash(algo, bin), case: :lower) <> "  " <> f)
          status

        {:error, r} ->
          IO.err(ctx, "#{name}: #{f}: #{:file.format_error(r)}")
          1
      end
    end)
  end

  defcmd "gpg", "OpenPGP encryption and signing, as GnuPG: keys (make, list, import, export), encrypt, decrypt, sign, verify",
    usage: "gpg [-e -r NAME | -c | -s | --clearsign | -b | -d | --verify | -k | -K | --import | --export | --quick-gen-key UID ...] [-a] [-o FILE] [FILE...]",
    aliases: ["gpg2"] do
    Lepton.PGP.CLI.run(args, ctx)
  end

  defcmd "cloc", "count lines of code: blank, comment and code lines by language, as cloc counts them",
    usage: "cloc [--by-file] [--json | --csv | --md] [--include-lang=L,...] [--exclude-dir=D,...] [--vcs=git] [-q] PATH..." do
    Lepton.Cloc.cli(args, ctx)
  end

  defcmd "tar", "create, list and extract tar archives, compressed too (.tar.gz, .tar.bz2, .tar.xz, .tar.zst), as GNU tar",
    usage: "tar -c|-x|-t [-v] [-z | -j | -J | --zstd] [-a] [-k] [-O] [-f ARCHIVE] [-C DIR] [--strip-components=N] [--exclude=PATTERN] [FILE...]" do
    Lepton.Archive.Tar.cli(args, ctx)
  end

  defcmd "unzip", "list, test and extract .zip archives, as Info-ZIP's unzip",
    usage: "unzip [-l | -v | -t | -p | -Z1] [-o | -n] [-q] [-j] [-d DIR] ZIPFILE [MEMBER...] [-x MEMBER...]" do
    Lepton.Archive.Zip.cli(args, ctx)
  end

  @shasum_algos %{"1" => :sha, "224" => :sha224, "256" => :sha256, "384" => :sha384, "512" => :sha512, "512224" => :sha512_224, "512256" => :sha512_256}

  defcmd "shasum", "print or check SHA checksums (SHA-1, -224, -256, -384, -512, -512/224, -512/256), as macOS's shasum",
    usage: "shasum [-a 1|224|256|384|512|512224|512256] [-b | -t] [--tag] [-c [-s] [-q] [-w]] [FILE...]" do
    case shasum_opts(args, %{algo: "1", mode: " ", tag: false, check: false, status: false, quiet: false, warn: false, files: []}) do
      {:error, msg} ->
        IO.err(ctx, "shasum: " <> msg)
        2

      %{check: true} = o ->
        shasum_check(ctx, o)

      o ->
        files = if o.files == [], do: ["-"], else: o.files
        algo = @shasum_algos[o.algo]

        Enum.reduce(files, 0, fn f, status ->
          case shasum_read(ctx, f) do
            {:ok, bin} ->
              hex = Base.encode16(:crypto.hash(algo, bin), case: :lower)
              IO.puts(ctx, if(o.tag, do: "#{shasum_tag(o.algo)} (#{f}) = #{hex}", else: hex <> " " <> o.mode <> f))
              status

            {:error, r} ->
              IO.err(ctx, "shasum: #{f}: #{:file.format_error(r)}")
              1
          end
        end)
    end
  end

  defp shasum_opts([a, alg | rest], o) when a in ["-a", "--algorithm"] do
    if Map.has_key?(@shasum_algos, alg), do: shasum_opts(rest, %{o | algo: alg}), else: {:error, "unrecognized algorithm #{alg} (1, 224, 256, 384, 512, 512224 or 512256)"}
  end

  defp shasum_opts(["-a" <> alg | rest], o) when alg != "", do: shasum_opts(["-a", alg | rest], o)
  defp shasum_opts([b | rest], o) when b in ["-b", "--binary"], do: shasum_opts(rest, %{o | mode: "*"})
  defp shasum_opts([t | rest], o) when t in ["-t", "--text", "-U", "--UNIVERSAL"], do: shasum_opts(rest, %{o | mode: " "})
  defp shasum_opts(["--tag" | rest], o), do: shasum_opts(rest, %{o | tag: true})
  defp shasum_opts([c | rest], o) when c in ["-c", "--check"], do: shasum_opts(rest, %{o | check: true})
  defp shasum_opts([s | rest], o) when s in ["-s", "--status"], do: shasum_opts(rest, %{o | status: true})
  defp shasum_opts([q | rest], o) when q in ["-q", "--quiet"], do: shasum_opts(rest, %{o | quiet: true})
  defp shasum_opts([w | rest], o) when w in ["-w", "--warn"], do: shasum_opts(rest, %{o | warn: true})
  defp shasum_opts(["--" | rest], o), do: %{o | files: o.files ++ rest}
  defp shasum_opts(["-" | rest], o), do: shasum_opts(rest, %{o | files: o.files ++ ["-"]})
  defp shasum_opts(["-" <> _ = flag | _], _o), do: {:error, "unknown option #{flag}"}
  defp shasum_opts([f | rest], o), do: shasum_opts(rest, %{o | files: o.files ++ [f]})
  defp shasum_opts([], o), do: o

  defp shasum_read(ctx, "-"), do: {:ok, IO.read_all(ctx.stdin)}
  defp shasum_read(ctx, f), do: File.read(Ctx.path(ctx, f))

  defp shasum_tag("1"), do: "SHA1"
  defp shasum_tag("512224"), do: "SHA512/224"
  defp shasum_tag("512256"), do: "SHA512/256"
  defp shasum_tag(n), do: "SHA" <> n

  # -c: lines "HASH  FILE" (" *FILE": binary), or "SHA256 (FILE) = HASH";
  # the algorithm from the hash's length (or the tag), as shasum does.
  defp shasum_check(ctx, o) do
    lists = if o.files == [], do: ["-"], else: o.files

    results =
      for list <- lists, line <- shasum_lines(ctx, list) do
        case shasum_parse(line) do
          {:ok, algo, hex, file} ->
            ok =
              case shasum_read(ctx, file) do
                {:ok, bin} -> Base.encode16(:crypto.hash(algo, bin), case: :lower) == String.downcase(hex)
                {:error, _} -> :missing
              end

            case ok do
              true -> if !o.status and !o.quiet, do: IO.puts(ctx, "#{file}: OK")
              false -> if !o.status, do: IO.puts(ctx, "#{file}: FAILED")
              :missing -> if !o.status, do: IO.puts(ctx, "#{file}: FAILED open or read")
            end

            ok

          :error ->
            if o.warn, do: IO.err(ctx, "shasum: #{list}: improperly formatted SHA checksum line")
            :bad
        end
      end

    failed = Enum.count(results, &(&1 in [false, :missing]))
    if failed > 0 and !o.status, do: IO.err(ctx, "shasum: WARNING: #{failed} computed checksum#{if failed == 1, do: "", else: "s"} did NOT match")
    cond do
      results == [] or Enum.all?(results, &(&1 == :bad)) -> IO.err(ctx, "shasum: no properly formatted SHA checksum lines found"); 1
      failed > 0 -> 1
      true -> 0
    end
  end

  defp shasum_lines(ctx, list) do
    case shasum_read(ctx, list) do
      {:ok, text} -> text |> String.split(~r/\r?\n/) |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#")))
      {:error, r} -> IO.err(ctx, "shasum: #{list}: #{:file.format_error(r)}"); []
    end
  end

  @doc false
  def shasum_parse(line) do
    by_len = %{40 => :sha, 56 => :sha224, 64 => :sha256, 96 => :sha384, 128 => :sha512}

    cond do
      m = Regex.run(~r/^SHA(1|224|256|384|512|512\/224|512\/256) \((.+)\) = ([0-9a-fA-F]+)$/, line, capture: :all_but_first) ->
        [alg, file, hex] = m
        {:ok, @shasum_algos[String.replace(alg, "/", "")], hex, file}

      m = Regex.run(~r/^([0-9a-fA-F]+) [ *?^U]?(.+)$/, line, capture: :all_but_first) ->
        [hex, file] = m
        case by_len[byte_size(hex)] do
          nil -> :error
          algo -> {:ok, algo, hex, file}
        end

      true ->
        :error
    end
  end

  defcmd "base64", "base64 encode/decode data", usage: "base64 [-d] [FILE]" do
    {opts, files} = getopt(args, "dw:")
    data = case files do
      [f | _] -> File.read!(Ctx.path(ctx, f))
      [] -> IO.read_all(ctx.stdin)
    end

    if opts["d"] do
      case Base.decode64(String.replace(data, ~r/\s/, "")) do
        {:ok, bin} -> IO.write(ctx, bin); 0
        :error -> IO.err(ctx, "base64: invalid input"); 1
      end
    else
      data |> Base.encode64() |> String.graphemes() |> Enum.chunk_every(76) |> Enum.each(&IO.puts(ctx, Enum.join(&1)))
      0
    end
  end

  defcmd "strings", "print printable character sequences in files", usage: "strings [FILE...]" do
    each_input(ctx, "strings", args, fn _f, lines ->
      data = Enum.join(lines)
      for [s] <- Regex.scan(~r/[\x20-\x7e]{4,}/, data), do: IO.puts(ctx, s)
    end)
  end

  defcmd "hexdump", "display file contents in hexadecimal", usage: "hexdump [FILE]", aliases: ["xxd"] do
    data = case args do
      [f | _] -> File.read!(Ctx.path(ctx, f))
      [] -> IO.read_all(ctx.stdin)
    end

    for {chunk, i} <- data |> :binary.bin_to_list() |> Enum.chunk_every(16) |> Enum.with_index() do
      hex = chunk |> Enum.map(&(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0") |> String.downcase())) |> Enum.chunk_every(2) |> Enum.map_join(" ", &Enum.join/1)
      ascii = chunk |> Enum.map(&if(&1 in 32..126, do: &1, else: ?.)) |> List.to_string()
      IO.puts(ctx, "#{(i * 16) |> Integer.to_string(16) |> String.pad_leading(8, "0") |> String.downcase()}: #{String.pad_trailing(hex, 40)}  #{ascii}")
    end

    0
  end

  # -- pager -----------------------------------------------------------------------------------

  defcmd "less", "view text one screen at a time (vi keys)", usage: "less [FILE]", aliases: ["more"] do
    text =
      case args do
        [f | _] ->
          case File.read(Ctx.path(ctx, f)) do
            {:ok, t} -> t
            {:error, r} -> IO.err(ctx, "less: #{f}: #{:file.format_error(r)}"); nil
          end

        [] ->
          IO.read_all(ctx.stdin)
      end

    cond do
      text == nil -> 1
      ctx.tty == nil or not Lepton.TTY.tty?(ctx.stdout) -> IO.write(ctx, text); 0
      true -> Lepton.Pager.run(ctx, text, List.first(args) || "stdin")
    end
  end
end
