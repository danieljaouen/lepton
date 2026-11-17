defmodule Lepton.Editor.Syntax do
  @moduledoc """
  Line-oriented syntax highlighting with the Monokai palette (the user's
  first `dotspacemacs-themes` entry). Token rules are regex based per
  major mode; selection/search spans are painted on top.
  """

  # Monokai via 256-colour approximations
  @comment "38;5;242"
  @string "38;5;186"
  @keyword "38;5;197"
  @function "38;5;148"
  @number "38;5;141"
  @atom "38;5;81"
  @type_color "38;5;81;3"
  @text "38;5;231"
  @heading "38;5;208;1"
  @added "38;5;148"
  @removed "38;5;197"

  @elixir_kw ~w(def defp defmodule defmacro defmacrop defstruct defprotocol defimpl defdelegate defguard defexception do end fn case cond with if unless else for receive after try rescue catch raise import alias require use quote unquote when in and or not true false nil)
  @erlang_kw ~w(case of end if receive after when fun try catch begin module export import record define)
  @shell_kw ~w(if then else elif fi for in do done while until case esac function return export local alias source)
  @lisp_kw ~w(defun defvar defcustom setq setq-default let let* lambda if when unless progn cond and or define-key global-set-key with-eval-after-load add-hook require)
  @python_kw ~w(def class if elif else for while in return import from as with try except finally raise pass break continue lambda yield None True False and or not is)

  def rules(mode) do
    case mode do
      m when m in ["Elixir", "EEx", "HEEx"] ->
        [
          {~r/#.*$/u, @comment},
          {~r/"(?:[^"\\\\]|\\\\.)*"?|'(?:[^'\\\\]|\\\\.)*'?|~[a-zA-Z]\/[^\/]*\/|~[a-zA-Z]\([^)]*\)/u, @string},
          {~r/@[a-z_]+/u, @atom},
          {~r/:[a-zA-Z_][a-zA-Z0-9_?!]*|\b[a-z_][a-zA-Z0-9_?!]*:(?=\s)/u, @atom},
          {~r/\b[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\b/u, @type_color},
          {keywords(@elixir_kw), @keyword},
          {~r/\b\d[\d_]*(?:\.\d+)?\b/u, @number},
          {~r/\b[a-z_][a-zA-Z0-9_?!]*(?=\()/u, @function}
        ]

      "Erlang" ->
        [{~r/%.*$/u, @comment}, {~r/"(?:[^"\\\\]|\\\\.)*"?/u, @string}, {~r/\?[A-Z_a-z]+/u, @atom}, {~r/\b[A-Z_][A-Za-z0-9_]*\b/u, @type_color}, {keywords(@erlang_kw), @keyword}, {~r/\b\d+\b/u, @number}, {~r/\b[a-z][a-zA-Z0-9_]*(?=\()/u, @function}]

      m when m in ["Shell-script", "Conf", "TOML", "YAML"] ->
        [{~r/(?<![\w$])#.*$/u, @comment}, {~r/"(?:[^"\\\\]|\\\\.)*"?|'[^']*'?/u, @string}, {~r/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/u, @atom}, {~r/^\s*\[[^\]]+\]/u, @heading}, {keywords(@shell_kw ++ ~w(bind bind-key unbind set setw set-option set-window-option)), @keyword}, {~r/\b\d+\b/u, @number}]

      m when m in ["Emacs-Lisp", "Lisp", "Clojure"] ->
        [{~r/;.*$/u, @comment}, {~r/"(?:[^"\\\\]|\\\\.)*"?/u, @string}, {~r/'[a-zA-Z\-\/*]+/u, @atom}, {keywords(@lisp_kw), @keyword}, {~r/\b\d+\b/u, @number}, {~r/(?<=\()[a-zA-Z\-\/*]+/u, @function}]

      "Python" ->
        [{~r/#.*$/u, @comment}, {~r/"(?:[^"\\\\]|\\\\.)*"?|'(?:[^'\\\\]|\\\\.)*'?/u, @string}, {keywords(@python_kw), @keyword}, {~r/\b\d+\b/u, @number}, {~r/\b[a-z_][a-zA-Z0-9_]*(?=\()/u, @function}]

      m when m in ["Markdown", "Org"] ->
        [{~r/^(#+|\*+) .*/u, @heading}, {~r/`[^`]*`/u, @string}, {~r/\*\*[^*]+\*\*/u, @keyword}]

      m when m in ["Diff", "Git-Commit"] ->
        [{~r/^\+.*/u, @added}, {~r/^-.*/u, @removed}, {~r/^@@.*/u, @atom}, {~r/^#.*/u, @comment}]

      "Special" ->
        [{~r/^(Head|Merge|Push|Untracked files|Unstaged changes|Staged changes|Recent commits|Unpulled|Unpushed|Search|Key bindings|From your|Leader|Variables)\b.*/u, @heading}, {~r/^\s*(modified|new file|deleted|renamed)\b/u, @keyword}, {~r/\b[0-9a-f]{7}\b/u, @number}, {~r/^\+[^+].*|^\+$/u, @added}, {~r/^-[^-].*|^-$/u, @removed}, {~r/^@@.*/u, @atom}]

      "Dired" ->
        [{~r/^  .*\/$/u, "38;5;81;1"}, {~r/^  \/.*:$/u, @heading}]

      _ ->
        []
    end
  end

  defp keywords(list), do: Regex.compile!("\\b(?:" <> Enum.map_join(list, "|", &Regex.escape/1) <> ")\\b(?![?!:])", "u")

  @doc """
  Highlight a visible slice of a line. `spans` are selection ranges in
  buffer columns; `left` is the horizontal scroll offset.
  """
  def highlight(text, mode, spans, left, show_ws) do
    g = String.graphemes(text)
    n = length(g)

    if n == 0 do
      ""
    else
      colors = :array.new(n, default: @text)
      colors = Enum.reduce(rules(mode), colors, fn {re, color}, arr -> paint(arr, text, re, color) end)

      colors =
        Enum.reduce(spans || [], colors, fn {from, to}, arr ->
          Enum.reduce(max(from - left, 0)..min(to - left - 1, n - 1)//1, arr, fn i, arr ->
            :array.set(i, :array.get(i, arr) <> ";48;5;59", arr)
          end)
        end)

      g
      |> Enum.with_index()
      |> Enum.chunk_by(fn {_, i} -> :array.get(i, colors) end)
      |> Enum.map_join(fn chunk ->
        {_, i} = hd(chunk)
        txt = Enum.map_join(chunk, &elem(&1, 0))
        txt = if show_ws, do: String.replace(txt, " ", "·"), else: txt
        "\e[" <> :array.get(i, colors) <> "m" <> txt <> "\e[39;22;23;49m\e[48;5;235m"
      end)
    end
  end

  # First rule wins for a cell, mirroring font-lock's precedence for comments/strings.
  defp paint(arr, text, re, color) do
    Regex.scan(re, text, return: :index)
    |> Enum.reduce(arr, fn [{start, len} | _], arr ->
      s = String.length(binary_part(text, 0, start))
      e = s + String.length(binary_part(text, start, len))

      Enum.reduce(s..(e - 1)//1, arr, fn i, arr ->
        if :array.get(i, arr) == @text, do: :array.set(i, color, arr), else: arr
      end)
    end)
  end
end

defmodule Lepton.Editor.Snippets do
  @moduledoc """
  yasnippet-compatible snippet expansion (`yas-expand`, used by the user's
  `my-tab-command` on `C-y ,`).

  Snippets are read from `~/.emacs.d/snippets/<mode>/` and
  `~/.spacemacs.d/snippets/<mode>/` in yasnippet's file format
  (`# key:`, `# --`, `$1`/`${1:default}`/`$0` fields). A few Elixir
  snippets are built in.
  """

  alias Lepton.Editor.Buffer

  @builtin %{
    "elixir-mode" => %{
      "def" => "def ${1:name}(${2:args}) do\n  $0\nend",
      "defp" => "defp ${1:name}(${2:args}) do\n  $0\nend",
      "defmodule" => "defmodule ${1:Name} do\n  $0\nend",
      "case" => "case ${1:expr} do\n  $0\nend",
      "test" => "test \"${1:description}\" do\n  $0\nend",
      "pry" => "require IEx; IEx.pry()$0",
      "ins" => "IO.inspect($0)"
    }
  }

  def mode_dir("Elixir"), do: "elixir-mode"
  def mode_dir("Python"), do: "python-mode"
  def mode_dir("Org"), do: "org-mode"
  def mode_dir("Erlang"), do: "erlang-mode"
  def mode_dir("Shell-script"), do: "sh-mode"
  def mode_dir("Emacs-Lisp"), do: "emacs-lisp-mode"
  def mode_dir(m), do: String.downcase(m) <> "-mode"

  def load(home, mode) do
    dir = mode_dir(mode)

    files =
      for root <- [Path.join(home, ".emacs.d/snippets"), Path.join(home, ".spacemacs.d/snippets"), Path.join(home, ".emacs.d/private/snippets")],
          path <- Path.wildcard(Path.join([root, dir, "*"])),
          File.regular?(path),
          do: parse(Path.basename(path), File.read!(path))

    Map.merge(Map.get(@builtin, dir, %{}), Map.new(files))
  end

  def parse(name, text) do
    case String.split(text, ~r/^# --\s*$/m, parts: 2) do
      [header, body] ->
        key = case Regex.run(~r/^# key:\s*(.+)$/m, header) do
          [_, k] -> String.trim(k)
          nil -> name
        end

        {key, String.trim_leading(body, "\n") |> String.trim_trailing("\n")}

      [body] ->
        {name, body}
    end
  end

  @doc "Expand the snippet whose key precedes the cursor. Returns {{buffer, cursor}, expanded?}."
  def expand(st, b, {l, c}) do
    line = Buffer.line(b, l)
    before = String.slice(line, 0, c)
    snippets = load(Lepton.Ctx.home(st.ctx), b.mode)

    found =
      snippets
      |> Enum.sort_by(fn {k, _} -> -String.length(k) end)
      |> Enum.find(fn {k, _} -> String.ends_with?(before, k) and (String.length(before) == String.length(k) or not (String.at(before, -String.length(k) - 1) =~ ~r/[\w]/u)) end)

    case found do
      nil ->
        {{b, {l, c}}, false}

      {key, body} ->
        indent = String.slice(line, 0, String.length(line) - String.length(String.trim_leading(line)))
        {text, cursor_offset} = render(body, indent)
        start = c - String.length(key)
        {b, _} = Buffer.delete_range(b, {l, start}, {l, c})
        {b, _} = Buffer.insert(b, {l, start}, text)
        {dl, dc} = cursor_offset
        pos = if dl == 0, do: {l, start + dc}, else: {l + dl, dc}
        {{b, pos}, true}
    end
  end

  # Replace fields with their defaults and find where $0 (or $1) lands.
  defp render(body, indent) do
    body = String.replace(body, "\n", "\n" <> indent)
    marker = "\u0000"

    text =
      body
      |> then(&Regex.replace(~r/\$\{0(?::([^}]*))?\}|\$0/, &1, fn _, d -> marker <> (d || "") end))
      |> then(&Regex.replace(~r/\$\{\d+:([^}]*)\}/, &1, "\\1"))
      |> then(&Regex.replace(~r/\$\d+/, &1, ""))
      |> then(&Regex.replace(~r/`[^`]*`/, &1, ""))

    {text, offset} =
      case String.split(text, marker, parts: 2) do
        [a, b] -> {a <> b, a}
        [a] -> {a, a}
      end

    lines = String.split(offset, "\n")
    {text, {length(lines) - 1, String.length(List.last(lines))}}
  end
end
