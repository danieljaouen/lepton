defmodule Lepton.Editor.Buffer do
  @moduledoc """
  A text buffer: its lines (binaries, no trailing newline; kept in chunks,
  `Lepton.Editor.Lines`) plus
  metadata and undo history. Positions are `{line, col}` with 0-based
  line numbers and grapheme columns.
  """

  alias Lepton.Editor.Lines

  defstruct id: nil,
            name: "*scratch*",
            path: nil,
            lines: Lines.new([""]),
            modified: false,
            kind: :file,
            mode: "Text",
            undo: [],
            redo: [],
            meta: %{},
            trailing_newline: true,
            read_only: false,
            folds: MapSet.new(),
            revealed: MapSet.new(),
            # marks (m): %{"a" => {line, column}}, moved with the lines as they're edited
            marks: %{}

  @undo_limit 200

  def new(name, text \\ "", opts \\ []) do
    {lines, nl} = split(text)

    %__MODULE__{
      id: opts[:id] || System.unique_integer([:positive]),
      name: name,
      path: opts[:path],
      lines: lines,
      kind: opts[:kind] || :file,
      mode: opts[:mode] || mode_for(opts[:path] || name),
      meta: opts[:meta] || %{},
      trailing_newline: nl,
      read_only: opts[:read_only] || false
    }
  end

  def from_file(path) do
    text =
      case File.read(path) do
        {:ok, t} -> t
        {:error, :enoent} -> ""
        {:error, r} -> raise "cannot read #{path}: #{:file.format_error(r)}"
      end

    new(Path.basename(path), text, path: path)
  end

  defp split(""), do: {Lines.new([""]), true}

  defp split(text) do
    text = String.replace(text, "\r\n", "\n")
    nl = String.ends_with?(text, "\n")
    parts = String.split(text, "\n")
    parts = if nl, do: Enum.drop(parts, -1), else: parts
    {Lines.new(parts), nl}
  end

  def text(b) do
    body = b.lines |> Lines.to_list() |> Enum.join("\n")
    if b.trailing_newline and body != "", do: body <> "\n", else: body
  end

  def line_count(b), do: Lines.size(b.lines)
  def line(b, i), do: Lines.at(b.lines, i) || ""
  def line_length(b, i), do: String.length(line(b, i))
  def lines(b), do: Lines.to_list(b.lines)

  def set_lines(b, list), do: %{b | lines: Lines.new(list), modified: true}

  # -- undo -----------------------------------------------------------------------------

  @doc "Record the current state before a change; `cursor` is restored on undo."
  def snapshot(b, cursor) do
    %{b | undo: Enum.take([{b.lines, cursor, b.modified} | b.undo], @undo_limit), redo: []}
  end

  def undo(%{undo: []} = b, _cursor), do: {b, nil}

  def undo(%{undo: [{lines, c, mod} | rest]} = b, cursor) do
    {%{b | lines: lines, undo: rest, redo: [{b.lines, cursor, b.modified} | b.redo], modified: mod}, c}
  end

  def redo(%{redo: []} = b, _cursor), do: {b, nil}

  def redo(%{redo: [{lines, c, _} | rest]} = b, cursor) do
    {%{b | lines: lines, redo: rest, undo: [{b.lines, cursor, b.modified} | b.undo], modified: true}, c}
  end

  # -- editing ------------------------------------------------------------------------------

  @doc "Insert text (may contain newlines) at {l, c}; returns {buffer, cursor_after}."
  def insert(b, {l, c}, text) do
    cur = line(b, l)
    {before, after_} = String.split_at(cur, c)
    pieces = String.split(text, "\n")

    new_lines =
      case pieces do
        [single] -> [before <> single <> after_]
        [first | rest] ->
          {mid, [last]} = Enum.split(rest, -1)
          [before <> first] ++ mid ++ [last <> after_]
      end

    b = replace_lines(b, l, l, new_lines)
    last_piece = List.last(pieces)

    cursor =
      if length(pieces) == 1,
        do: {l, c + String.length(text)},
        else: {l + length(pieces) - 1, String.length(last_piece)}

    {b, cursor}
  end

  @doc "Replace lines l1..l2 (inclusive) with `new_lines`."
  def replace_lines(b, l1, l2, new_lines), do: %{b | lines: Lines.replace(b.lines, l1, l2, new_lines), modified: true}

  @doc "Text between two positions, end exclusive."
  def get_range(b, {l1, c1}, {l2, c2}) do
    if l1 == l2 do
      String.slice(line(b, l1), c1, max(c2 - c1, 0))
    else
      first = String.slice(line(b, l1), c1..-1//1)
      mids = for i <- (l1 + 1)..(l2 - 1)//1, do: line(b, i)
      last = String.slice(line(b, l2), 0, c2)
      Enum.join([first | mids] ++ [last], "\n")
    end
  end

  @doc "Delete between two positions (end exclusive); returns {buffer, deleted_text}."
  def delete_range(b, {l1, c1} = from, {l2, c2} = to) do
    text = get_range(b, from, to)
    first = String.slice(line(b, l1), 0, c1)
    last = String.slice(line(b, l2), c2..-1//1)
    {replace_lines(b, l1, l2, [first <> last]), text}
  end

  def get_lines(b, l1, l2), do: Lines.slice(b.lines, l1, l2)

  def delete_lines(b, l1, l2) do
    l2 = min(l2, line_count(b) - 1)
    deleted = get_lines(b, l1, l2)
    {replace_lines(b, l1, l2, []), deleted}
  end

  def insert_lines(b, at, new_lines), do: replace_lines(b, at, at - 1, new_lines)

  # -- files --------------------------------------------------------------------------------

  def save(%{path: nil}), do: {:error, "no file name"}

  def save(b) do
    File.mkdir_p(Path.dirname(b.path))

    case File.write(b.path, text(b)) do
      :ok -> {:ok, %{b | modified: false}}
      {:error, r} -> {:error, :file.format_error(r) |> to_string()}
    end
  end

  def delete_trailing_whitespace(b) do
    set_lines(b, Enum.map(lines(b), &String.trim_trailing/1)) |> Map.put(:modified, b.modified or lines(b) != Enum.map(lines(b), &String.trim_trailing/1))
  end

  @modes %{
    ".ex" => "Elixir",
    ".exs" => "Elixir",
    ".eex" => "EEx",
    ".heex" => "HEEx",
    ".erl" => "Erlang",
    ".hrl" => "Erlang",
    ".el" => "Emacs-Lisp",
    ".py" => "Python",
    ".rb" => "Ruby",
    ".js" => "JavaScript",
    ".ts" => "TypeScript",
    ".md" => "Markdown",
    ".org" => "Org",
    ".sh" => "Shell-script",
    ".zsh" => "Shell-script",
    ".json" => "JSON",
    ".toml" => "TOML",
    ".yml" => "YAML",
    ".yaml" => "YAML",
    ".c" => "C",
    ".h" => "C",
    ".lisp" => "Lisp",
    ".clj" => "Clojure",
    ".html" => "HTML",
    ".css" => "CSS",
    ".diff" => "Diff",
    ".patch" => "Diff",
    ".typ" => "Typst"
  }

  def mode_for(nil), do: "Text"

  def mode_for(name) do
    base = Path.basename(name)

    cond do
      base in ["COMMIT_EDITMSG"] -> "Git-Commit"
      base in [".zshrc", ".bashrc", ".lshrc", "lshrc"] -> "Shell-script"
      base in [".tmux.conf", ".gitconfig"] -> "Conf"
      base in [".spacemacs"] -> "Emacs-Lisp"
      true -> Map.get(@modes, Path.extname(base), "Text")
    end
  end

  @doc "Line comment prefix for the buffer's mode."
  def comment_prefix(b) do
    case b.mode do
      m when m in ["Elixir", "Shell-script", "Python", "Ruby", "YAML", "TOML", "Conf"] -> "# "
      m when m in ["Erlang"] -> "% "
      m when m in ["Emacs-Lisp", "Lisp", "Clojure"] -> ";; "
      m when m in ["JavaScript", "TypeScript", "C", "CSS", "Typst"] -> "// "
      _ -> "# "
    end
  end

  def indent_unit(b), do: if(b.mode in ["Python", "C"], do: "    ", else: "  ")
end
