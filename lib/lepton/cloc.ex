defmodule Lepton.Cloc do
  @moduledoc """
  Counting lines of code (`cloc`): for each file, its blank lines,
  comment lines and code lines, by language, as cloc (AlDanial's) counts
  them. A line with code and a trailing comment is code; one inside a
  block comment, or (Elixir) inside a `@moduledoc`, `@doc` or `@typedoc`
  heredoc, is a comment, as cloc's filters make it. Identical files
  count once.
  """

  # {name, extensions (or exact file names), line comments, block comments}
  @languages [
    {"Elixir", ~w(.ex), ["#"], []},
    {"Elixir Script", ~w(.exs), ["#"], []},
    {"Erlang", ~w(.erl .hrl .app.src .escript), ["%"], []},
    {"HEEx", ~w(.heex), [], [{"<%!--", "--%>"}, {"<!--", "-->"}]},
    {"EEx", ~w(.eex .leex), [], [{"<%#", "%>"}]},
    {"Markdown", ~w(.md .markdown), [], [{"<!--", "-->"}]},
    {"HTML", ~w(.html .htm), [], [{"<!--", "-->"}]},
    {"XML", ~w(.xml .svg .plist), [], [{"<!--", "-->"}]},
    {"CSS", ~w(.css), [], [{"/*", "*/"}]},
    {"SCSS", ~w(.scss), ["//"], [{"/*", "*/"}]},
    {"JavaScript", ~w(.js .mjs .cjs .jsx), ["//"], [{"/*", "*/"}]},
    {"TypeScript", ~w(.ts .tsx), ["//"], [{"/*", "*/"}]},
    {"JSON", ~w(.json), [], []},
    {"YAML", ~w(.yml .yaml), ["#"], []},
    {"TOML", ~w(.toml), ["#"], []},
    {"Bourne Shell", ~w(.sh), ["#"], []},
    {"Bourne Again Shell", ~w(.bash), ["#"], []},
    {"zsh", ~w(.zsh .zshrc), ["#"], []},
    {"Python", ~w(.py), ["#"], []},
    {"Ruby", ~w(.rb .rake Rakefile Gemfile), ["#"], [{"=begin", "=end"}]},
    {"C", ~w(.c), ["//"], [{"/*", "*/"}]},
    {"C/C++ Header", ~w(.h .hpp .hh), ["//"], [{"/*", "*/"}]},
    {"C++", ~w(.cpp .cc .cxx), ["//"], [{"/*", "*/"}]},
    {"Rust", ~w(.rs), ["//"], [{"/*", "*/"}]},
    {"Go", ~w(.go), ["//"], [{"/*", "*/"}]},
    {"Java", ~w(.java), ["//"], [{"/*", "*/"}]},
    {"Kotlin", ~w(.kt .kts), ["//"], [{"/*", "*/"}]},
    {"Swift", ~w(.swift), ["//"], [{"/*", "*/"}]},
    {"Lua", ~w(.lua), ["--"], [{"--[[", "]]"}]},
    {"SQL", ~w(.sql), ["--"], [{"/*", "*/"}]},
    {"Lisp", ~w(.lisp .lsp .cl), [";"], [{"#|", "|#"}]},
    {"Emacs Lisp", ~w(.el), [";"], []},
    {"Clojure", ~w(.clj .cljs .cljc .edn), [";"], []},
    {"Haskell", ~w(.hs), ["--"], [{"{-", "-}"}]},
    {"make", ~w(Makefile makefile GNUmakefile .mk .mak), ["#"], []},
    {"Dockerfile", ~w(Dockerfile), ["#"], []},
    {"Nix", ~w(.nix), ["#"], [{"/*", "*/"}]},
    {"Typst", ~w(.typ), ["//"], [{"/*", "*/"}]},
    {"TeX", ~w(.tex .sty .cls), ["%"], []},
    {"PHP", ~w(.php), ["//", "#"], [{"/*", "*/"}]},
    {"Perl", ~w(.pl .pm), ["#"], [{"=pod", "=cut"}]},
    {"Vim Script", ~w(.vim), ["\""], []},
    {"Text", ~w(.txt), [], []}
  ]

  @skip_dirs ~w(.git .hg .svn .bzr CVS)
  @elixir_docs ~r/^\s*@(moduledoc|doc|typedoc)\s+(~[sS])?("""|''')/

  def languages, do: @languages

  @doc """
  The language a path's file is in: its name or extension, else (no
  extension) its `#!` line's interpreter, as cloc finds them; or nil.
  """
  def language(path) do
    base = Path.basename(path)
    ext = Path.extname(base)
    ext2 = base |> Path.rootname() |> Path.extname() |> Kernel.<>(ext)

    Enum.find(@languages, fn {_, exts, _, _} -> base in exts or ext2 in exts or (ext != "" and ext in exts) end) ||
      if(ext == "", do: by_shebang(path))
  end

  @shebangs %{"sh" => "Bourne Shell", "ash" => "Bourne Shell", "dash" => "Bourne Shell", "bash" => "Bourne Again Shell", "zsh" => "zsh",
              "escript" => "Erlang", "python" => "Python", "python3" => "Python", "perl" => "Perl", "ruby" => "Ruby", "node" => "JavaScript",
              "elixir" => "Elixir Script", "lua" => "Lua"}

  defp by_shebang(path) do
    with {:ok, f} <- File.open(path, [:read, :binary]),
         line when is_binary(line) <- IO.binread(f, :line) |> tap(fn _ -> File.close(f) end),
         [_, prog] <- Regex.run(~r{^#!\s*\S*/(?:env\s+)?(\S+)}, line),
         name when is_binary(name) <- @shebangs[prog] do
      Enum.find(@languages, fn {n, _, _, _} -> n == name end)
    else
      _ -> nil
    end
  end

  @doc "A file's text counted: `%{blank, comment, code}`, for language `lang` (one of `languages/0`)."
  # Elixir: exactly cloc's filters (cloc 2.08), so its numbers are cloc's:
  # lines starting `#` go; `@doc """` / `@moduledoc """` to the next line
  # with `"""` become a C comment; then every C comment (`/* ... */`)
  # goes, across lines, as Regexp::Common's: `/*` in code ("**/*") too.
  # Comment lines: the non-blank lines that went, or became blank.
  def count(text, {lang, _, _, _}) when lang in ["Elixir", "Elixir Script"] do
    lines = split_lines(text)
    blank = Enum.count(lines, &blank?/1)
    nonblank = length(lines) - blank
    kept = Enum.reject(lines, &Regex.match?(~r/^\s*#/, &1))

    {converted, _} = Enum.map_reduce(kept, false, &doc_to_c/2)

    stripped = converted |> Enum.join("\n") |> strip_c_comments()
    code = stripped |> String.split("\n") |> Enum.reject(&blank?/1) |> length()
    %{blank: blank, comment: nonblank - code, code: code}
  end

  def count(text, {name, _, line_cs, block_cs}) do
    lines = String.split(text, ~r/\r?\n/)
    lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines

    {counts, _} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({%{blank: 0, comment: 0, code: 0}, nil}, fn {line, i}, {c, state} ->
        trimmed = String.trim(line)

        cond do
          # (a script's #! line is code, as cloc has it)
          i == 0 and String.starts_with?(line, "#!") ->
            {Map.update!(c, :code, &(&1 + 1)), nil}

          # Inside a block comment or an Elixir doc heredoc: until its end.
          state != nil ->
            {close, kind} = state
            done = if kind == :doc, do: String.starts_with?(trimmed, close), else: String.contains?(trimmed, close)
            key = if trimmed == "", do: :blank, else: :comment
            {Map.update!(c, key, &(&1 + 1)), if(done, do: nil, else: state)}

          trimmed == "" ->
            {Map.update!(c, :blank, &(&1 + 1)), nil}

          name == "Elixir" and Regex.match?(@elixir_docs, line) ->
            [_, _, _, q] = Regex.run(@elixir_docs, line)
            # (a one-line heredoc can't be; but `@doc """` ... `"""` can)
            {Map.update!(c, :comment, &(&1 + 1)), {q, :doc}}

          Enum.any?(line_cs, &String.starts_with?(trimmed, &1)) ->
            {Map.update!(c, :comment, &(&1 + 1)), nil}

          b = Enum.find(block_cs, fn {open, _} -> String.starts_with?(trimmed, open) end) ->
            {open, close} = b
            rest = String.slice(trimmed, String.length(open)..-1//1)

            case String.split(rest, close, parts: 2) do
              # closed on this line: a comment if nothing follows, else code
              [_, after_] -> if String.trim(after_) == "", do: {Map.update!(c, :comment, &(&1 + 1)), nil}, else: {Map.update!(c, :code, &(&1 + 1)), nil}
              [_] -> {Map.update!(c, :comment, &(&1 + 1)), {close, :block}}
            end

          true ->
            # Code; a block comment opening after it carries on.
            opened = Enum.find_value(block_cs, fn {open, close} ->
              case String.split(line, open, parts: 2) do
                [_, after_] -> if String.contains?(after_, close), do: nil, else: {close, :block}
                _ -> nil
              end
            end)

            {Map.update!(c, :code, &(&1 + 1)), opened}
        end
      end)

    counts
  end

  # cloc's elixir_doc_to_C: a doc's opening quotes become /*, the next
  # line's triple quotes */ (the first on the line, each).
  defp doc_to_c(line, false) do
    case Regex.run(~r/(@(module)?doc\s+(~[sScC])?['"]{3})/, line) do
      [m | _] -> {String.replace(line, m, "/*", global: false), true}
      nil -> {line, false}
    end
  end

  defp doc_to_c(line, true) do
    case Regex.run(~r/(['"]{3})/, line) do
      [m | _] -> {String.replace(line, m, "*/", global: false), false}
      nil -> {line, true}
    end
  end

  # Each /* to the next */ cut out (Regexp::Common's C comments); a /*
  # without its */ stays.
  defp strip_c_comments(text), do: text |> strip_c(<<>>) |> IO.iodata_to_binary()

  defp strip_c(text, acc) do
    case :binary.match(text, "/*") do
      :nomatch ->
        [acc, text]

      {open, 2} ->
        after_open = binary_part(text, open + 2, byte_size(text) - open - 2)

        case :binary.match(after_open, "*/") do
          :nomatch -> [acc, text]
          {close, 2} -> strip_c(binary_part(after_open, close + 2, byte_size(after_open) - close - 2), [acc, binary_part(text, 0, open)])
        end
    end
  end

  defp split_lines(text) do
    lines = String.split(text, ~r/\r?\n/)
    if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
  end

  defp blank?(line), do: String.trim(line) == ""

  @doc """
  Count everything under `paths`. Options: `:exclude_dirs`, `:include_langs`,
  `:exclude_langs`, `:exclude_exts`, `:match_f`, `:not_match_f` (regexes on
  file names), `:files` (the list to count instead of walking, as from
  `git ls-files`). Returns `%{files: [%{path, lang, blank, comment, code}],
  total_files, unique, ignored}`.
  """
  def run(paths, opts \\ []) do
    candidates = opts[:files] || Enum.flat_map(paths, &walk(&1, opts))
    {known, unknown} = Enum.split_with(candidates, &(language(&1) != nil))

    known =
      Enum.filter(known, fn p ->
        {lang, _, _, _} = language(p)
        base = Path.basename(p)

        (opts[:include_langs] in [nil, []] or lang in opts[:include_langs]) and
          lang not in (opts[:exclude_langs] || []) and
          String.trim_leading(Path.extname(p), ".") not in (opts[:exclude_exts] || []) and
          (opts[:match_f] == nil or Regex.match?(opts[:match_f], base)) and
          (opts[:not_match_f] == nil or not Regex.match?(opts[:not_match_f], base))
      end)

    read = for p <- known, {:ok, text} <- [File.read(p)], String.valid?(text) or not binary?(text), do: {p, text}
    unique = Enum.uniq_by(read, fn {_, text} -> :crypto.hash(:md5, text) end)

    files =
      for {p, text} <- unique do
        lang = language(p)
        Map.merge(%{path: p, lang: elem(lang, 0)}, count(text, lang))
      end

    %{files: files, total_files: length(candidates), unique: length(unique), ignored: length(candidates) - length(unique) + length(unknown) - length(unknown)}
  end

  defp binary?(text), do: String.contains?(binary_part(text, 0, min(byte_size(text), 8000)), <<0>>)

  defp walk(path, opts) do
    skip = @skip_dirs ++ (opts[:exclude_dirs] || [])

    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        case File.ls(path) do
          {:ok, names} ->
            names
            |> Enum.sort()
            |> Enum.reject(&(&1 in skip))
            |> Enum.flat_map(fn n ->
              full = Path.join(path, n)
              if File.dir?(full) and match?({:ok, %{type: :symlink}}, File.lstat(full)), do: [], else: walk(full, opts)
            end)

          _ ->
            []
        end

      true ->
        []
    end
  end

  # -- the command ------------------------------------------------------------------------------------------

  @doc "`cloc [OPTIONS] PATH...`: the report, as cloc prints it. Returns the exit status."
  def cli(args, ctx) do
    case cli_opts(args, %{paths: [], quiet: false, by_file: false, format: :table, rate: true, vcs: nil, opts: []}) do
      {:error, msg} ->
        Lepton.IO.err(ctx, "cloc: " <> msg)
        2

      %{show_lang: true} ->
        for {name, exts, _, _} <- @languages, do: Lepton.IO.puts(ctx, String.pad_trailing(name, 22) <> "(" <> Enum.join(exts, ", ") <> ")")
        0

      %{paths: [], vcs: nil} ->
        Lepton.IO.err(ctx, "usage: cloc [--by-file] [--json|--csv|--md] [--include-lang=L,..] [--exclude-dir=D,..] [--vcs=git] PATH...")
        2

      o ->
        paths = Enum.map(if(o.paths == [], do: ["."], else: o.paths), &Lepton.Ctx.path(ctx, &1))

        files =
          if o.vcs == "git" do
            Enum.flat_map(paths, fn p ->
              root = Lepton.Git.root(p) || p
              # (not into submodules: another repository's files, as git ls-files)
              for f <- Lepton.Git.worktree_files(Lepton.Git.Repo.open(root)),
                  not submodule?(root, f),
                  full = Path.join(root, f),
                  String.starts_with?(full, p),
                  File.regular?(full),
                  do: full
            end)
          end

        t0 = System.monotonic_time(:millisecond)
        r = run(paths, [files: files] ++ o.opts)
        secs = max(System.monotonic_time(:millisecond) - t0, 1) / 1000
        r = %{r | files: Enum.map(r.files, &%{&1 | path: Lepton.Ctx.tildify(ctx, Path.relative_to(&1.path, ctx.cwd || "/"))})}
        Lepton.IO.write(ctx, report(r, o, secs))
        0
    end
  end

  # Is a file (relative to `root`) in a folder of its own repository (a submodule)?
  defp submodule?(root, rel) do
    rel
    |> Path.dirname()
    |> Path.split()
    |> Enum.scan(&Path.join(&2, &1))
    |> Enum.any?(&(&1 != "." and File.exists?(Path.join([root, &1, ".git"]))))
  end

  defp cli_opts([], o), do: o

  defp cli_opts([arg | rest], o) do
    {flag, value} = case String.split(arg, "=", parts: 2) do
      [f, v] -> {f, v}
      [f] -> {f, nil}
    end

    list = fn -> (value || "") |> String.split(",", trim: true) end

    case flag do
      f when f in ["--quiet", "-q"] -> cli_opts(rest, %{o | quiet: true})
      "--by-file" -> cli_opts(rest, %{o | by_file: true})
      "--json" -> cli_opts(rest, %{o | format: :json})
      "--csv" -> cli_opts(rest, %{o | format: :csv})
      "--md" -> cli_opts(rest, %{o | format: :md})
      "--hide-rate" -> cli_opts(rest, %{o | rate: false})
      "--show-lang" -> cli_opts(rest, Map.put(o, :show_lang, true))
      "--vcs" -> cli_opts(rest, %{o | vcs: value || "git"})
      "--include-lang" -> cli_opts(rest, %{o | opts: [{:include_langs, list.()} | o.opts]})
      "--exclude-lang" -> cli_opts(rest, %{o | opts: [{:exclude_langs, list.()} | o.opts]})
      "--exclude-dir" -> cli_opts(rest, %{o | opts: [{:exclude_dirs, list.()} | o.opts]})
      "--exclude-ext" -> cli_opts(rest, %{o | opts: [{:exclude_exts, list.()} | o.opts]})
      f when f in ["--match-f", "--not-match-f"] ->
        case Regex.compile(value || "") do
          {:ok, re} -> cli_opts(rest, %{o | opts: [{if(f == "--match-f", do: :match_f, else: :not_match_f), re} | o.opts]})
          _ -> {:error, "#{f}: not a regular expression"}
        end

      "-" <> _ -> {:error, "unknown option #{arg}"}
      _ -> cli_opts(rest, %{o | paths: o.paths ++ [arg]})
    end
  end

  @rule String.duplicate("-", 79)

  @doc false
  def report(r, o, secs) do
    langs = by_language(r.files)
    sum = %{files: length(r.files), blank: total(langs, :blank), comment: total(langs, :comment), code: total(langs, :code)}

    rows =
      if o.by_file,
        do: Enum.map(Enum.sort_by(r.files, &{-&1.code, &1.path}), &{&1.path, &1}),
        else: Enum.map(langs, fn {l, t} -> {l, t} end)

    case o.format do
      :json ->
        body = if o.by_file, do: Map.new(rows, fn {p, f} -> {p, %{"blank" => f.blank, "comment" => f.comment, "code" => f.code, "language" => f.lang}} end), else: Map.new(rows, fn {l, t} -> {l, %{"nFiles" => t.files, "blank" => t.blank, "comment" => t.comment, "code" => t.code}} end)
        JSON.encode!(Map.merge(body, %{"header" => %{"cloc_version" => "Lepton", "n_files" => sum.files, "n_lines" => sum.blank + sum.comment + sum.code}, "SUM" => %{"nFiles" => sum.files, "blank" => sum.blank, "comment" => sum.comment, "code" => sum.code}})) <> "\n"

      :csv ->
        head = if o.by_file, do: "language,filename,blank,comment,code\n", else: "files,language,blank,comment,code\n"
        lines = if o.by_file, do: Enum.map(rows, fn {p, f} -> "#{f.lang},#{p},#{f.blank},#{f.comment},#{f.code}\n" end), else: Enum.map(rows, fn {l, t} -> "#{t.files},#{l},#{t.blank},#{t.comment},#{t.code}\n" end)
        IO.iodata_to_binary([head, lines, "#{sum.files},SUM,#{sum.blank},#{sum.comment},#{sum.code}\n"])

      :md ->
        first = if o.by_file, do: "File", else: "Language"
        head = "#{first}|#{if o.by_file, do: "", else: "files|"}blank|comment|code\n:-------|#{if o.by_file, do: "", else: "-------:|"}-------:|-------:|-------:\n"
        lines = Enum.map(rows, fn {n, t} -> "#{n}|#{if o.by_file, do: "", else: "#{t.files}|"}#{t.blank}|#{t.comment}|#{t.code}\n" end)
        IO.iodata_to_binary([head, lines, "SUM:|#{if o.by_file, do: "", else: "#{sum.files}|"}#{sum.blank}|#{sum.comment}|#{sum.code}\n"])

      :table ->
        header =
          if o.quiet do
            ""
          else
            lines = sum.blank + sum.comment + sum.code
            rate = if o.rate, do: "  T=#{Float.round(secs, 2)} s (#{Float.round(sum.files / secs, 1)} files/s, #{Float.round(lines / secs, 1)} lines/s)", else: ""

            "#{String.pad_leading(to_string(r.total_files), 8)} text files.\n#{String.pad_leading(to_string(r.unique), 8)} unique files.\n#{String.pad_leading(to_string(r.total_files - length(r.files)), 8)} files ignored.\n\n" <>
              "cloc (Lepton, counting as cloc 2.08)#{rate}\n"
          end

        col = fn n -> String.pad_leading(to_string(n), 15) end
        {first, files_col} = if o.by_file, do: {"File", ""}, else: {"Language", String.pad_leading("files", 9)}
        width = if o.by_file, do: max(34, (rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max(fn -> 0 end)) + 2), else: 25

        name = fn n -> if String.length(n) > width - 1 and o.by_file, do: n, else: String.pad_trailing(n, width) end
        rule = String.duplicate("-", max(79, width + 45 + if(o.by_file, do: 0, else: 9)))
        _ = @rule

        body =
          Enum.map(rows, fn {n, t} ->
            name.(n) <> if(o.by_file, do: "", else: String.pad_leading(to_string(t.files), 9)) <> col.(t.blank) <> col.(t.comment) <> col.(t.code) <> "\n"
          end)

        IO.iodata_to_binary([
          header,
          rule, "\n",
          String.pad_trailing(first, width), files_col, String.pad_leading("blank", 15), String.pad_leading("comment", 15), String.pad_leading("code", 15), "\n",
          rule, "\n",
          body,
          rule, "\n",
          name.("SUM:"), if(o.by_file, do: "", else: String.pad_leading(to_string(sum.files), 9)), col.(sum.blank), col.(sum.comment), col.(sum.code), "\n",
          rule, "\n"
        ])
    end
  end

  defp total(langs, k), do: langs |> Enum.map(fn {_, t} -> Map.fetch!(t, k) end) |> Enum.sum()

  @doc "Totals by language: `[{lang, %{files, blank, comment, code}}]`, most code first."
  def by_language(files) do
    files
    |> Enum.group_by(& &1.lang)
    |> Enum.map(fn {lang, fs} -> {lang, %{files: length(fs), blank: sum(fs, :blank), comment: sum(fs, :comment), code: sum(fs, :code)}} end)
    |> Enum.sort_by(fn {lang, t} -> {-t.code, lang} end)
  end

  defp sum(fs, k), do: fs |> Enum.map(&Map.fetch!(&1, k)) |> Enum.sum()
end
