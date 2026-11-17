defmodule Lepton.TOML do
  @moduledoc """
  A small TOML reader covering what configuration files use in practice:
  tables, dotted table names, strings (basic, literal, multi-line), integers,
  floats, booleans and flat arrays.
  """

  def parse(text) do
    {table, _current, _pending} =
      text
      |> String.replace("\r\n", "\n")
      |> join_multiline()
      |> String.split("\n")
      |> Enum.reduce({%{}, [], nil}, &line/2)

    table
  end

  def read(path) do
    case File.read(path) do
      {:ok, text} -> parse(text)
      _ -> %{}
    end
  end

  # Fold """...""" values onto one line, keeping embedded newlines escaped.
  defp join_multiline(text) do
    Regex.replace(~r/"""\n?(.*?)"""/s, text, fn _, body ->
      "\"" <> (body |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")) <> "\""
    end)
  end

  defp line(raw, {table, current, nil}) do
    line = String.trim(raw)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        {table, current, nil}

      m = Regex.run(~r/^\[([^\]]+)\]\s*(#.*)?$/, line) ->
        path = m |> Enum.at(1) |> String.split(".") |> Enum.map(&(&1 |> String.trim() |> String.trim("\"")))
        {table, path, nil}

      m = Regex.run(~r/^([A-Za-z0-9_\-"\.]+)\s*=\s*(.+)$/, line) ->
        [_, key, value] = m
        key = String.trim(key, "\"")
        {put(table, current ++ [key], value(String.trim(value))), current, nil}

      true ->
        {table, current, nil}
    end
  end

  defp put(table, [k], v), do: Map.put(table, k, v)
  defp put(table, [k | rest], v), do: Map.put(table, k, put(Map.get(table, k, %{}), rest, v))

  def value("\"" <> _ = s), do: basic_string(s)
  def value("'" <> rest), do: rest |> String.split("'", parts: 2) |> hd()
  def value("true" <> _), do: true
  def value("false" <> _), do: false

  def value("[" <> _ = s) do
    inner = s |> String.trim() |> String.trim_leading("[") |> String.replace(~r/\]\s*(#.*)?$/, "")

    Regex.scan(~r/"(?:[^"\\]|\\.)*"|'[^']*'|[^,\s]+/, inner)
    |> Enum.map(fn [item] -> value(item) end)
  end

  def value(s) do
    s = s |> String.split("#") |> hd() |> String.trim()

    cond do
      Regex.match?(~r/^-?\d+$/, s) -> String.to_integer(s)
      Regex.match?(~r/^-?\d+\.\d+$/, s) -> String.to_float(s)
      true -> s
    end
  end

  defp basic_string("\"" <> rest) do
    {chars, _} = take_string(rest, [])
    chars
  end

  defp take_string("\"" <> rest, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp take_string("\\n" <> rest, acc), do: take_string(rest, ["\n" | acc])
  defp take_string("\\t" <> rest, acc), do: take_string(rest, ["\t" | acc])
  defp take_string("\\\"" <> rest, acc), do: take_string(rest, ["\"" | acc])
  defp take_string("\\\\" <> rest, acc), do: take_string(rest, ["\\" | acc])

  defp take_string("\\u" <> <<hex::binary-size(4), rest::binary>>, acc),
    do: take_string(rest, [<<String.to_integer(hex, 16)::utf8>> | acc])

  defp take_string(<<c::utf8, rest::binary>>, acc), do: take_string(rest, [<<c::utf8>> | acc])
  defp take_string("", acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}
end
