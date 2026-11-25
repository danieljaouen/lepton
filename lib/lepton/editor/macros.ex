defmodule Lepton.Editor.Macros do
  @moduledoc """
  `le`'s keyboard macros kept across sessions: each one recorded (`qa`
  ... `q`) is saved to `$XDG_STATE_HOME/le/macros` (by default
  `~/.local/state/le/macros`), and `le` loads them when it starts.

  One macro a line, its register and then its keys, as an Elixir list:

      a ["0", "i", "-", " ", "ESC", "j"]

  The file can be edited by hand; a line that doesn't read as a register
  and a list of keys is skipped. Saving merges with the file, so macros
  recorded in two `le` sessions at once are both kept.
  """

  @doc "The macros file for this session's environment."
  def path(ctx) do
    state = Lepton.Ctx.get_env(ctx, "XDG_STATE_HOME", nil)
    state = if state in [nil, ""], do: Path.join(Lepton.Ctx.home(ctx), ".local/state"), else: state
    Path.join([state, "le", "macros"])
  end

  @doc "The macros saved in `file`, `%{register => keys}` (none if it's missing)."
  def load(file) do
    case File.read(file) do
      {:ok, text} -> text |> String.split("\n") |> Enum.flat_map(&parse_line/1) |> Map.new()
      _ -> %{}
    end
  end

  @doc "Save `keys` as register `reg`'s macro in `file` (merged with what's there)."
  def save(file, reg, keys) do
    # (a mouse click recorded in it isn't kept: it means nothing elsewhere)
    macros = file |> load() |> Map.put(reg, Enum.filter(keys, &key?/1))

    text =
      [
        "# le's keyboard macros: a register, then its keys (saved when one is recorded)\n"
        | for({r, k} <- Enum.sort(macros), do: "#{r} #{encode(k)}\n")
      ]

    Lepton.Users.own_new_in_home(file, fn ->
      File.mkdir_p(Path.dirname(file))
      tmp = file <> ".tmp"

      with :ok <- File.write(tmp, text), :ok <- File.rename(tmp, file) do
        :ok
      else
        err -> File.rm(tmp); err
      end
    end)
  end

  # One line, whatever is in the keys: inspect escapes newlines, returns,
  # tabs and escapes ("\n", "\r", "\t", "\e"), and writes bytes that aren't
  # UTF-8 as "\xFF" rather than <<255>>, so that every key reads back as
  # the string it was.
  @doc false
  def encode(keys), do: inspect(keys, limit: :infinity, printable_limit: :infinity, binaries: :as_strings)

  defp parse_line(line) do
    with [reg, list] <- String.split(String.trim(line), " ", parts: 2),
         true <- reg =~ ~r/^[a-z0-9]$/,
         {:ok, quoted} <- Code.string_to_quoted(list, existing_atoms_only: true),
         true <- is_list(quoted) and Enum.all?(quoted, &key?/1) do
      [{reg, Enum.map(quoted, &key/1)}]
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # Keys are strings ("j", "C-a", "ESC"), or {:paste, text}: literals only,
  # nothing in the file is run.
  defp key?(k) when is_binary(k), do: true
  defp key?({:paste, t}) when is_binary(t), do: true
  defp key?(_), do: false

  defp key({:paste, t}), do: {:paste, t}
  defp key(k), do: k
end
