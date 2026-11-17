defmodule LeptonBuild.Ar do
  @moduledoc "Reader for Unix `ar` archives (the container format of .deb packages)."

  @magic "!<arch>\n"

  def entries(@magic <> rest), do: read(rest, [])
  def entries(_), do: raise(ArgumentError, "not an ar archive")

  defp read(<<>>, acc), do: Enum.reverse(acc)
  defp read("\n" <> rest, acc), do: read(rest, acc)

  defp read(<<header::binary-size(60), rest::binary>>, acc) do
    <<name::binary-size(16), _meta::binary-size(32), size::binary-size(10), "`\n">> = header
    size = size |> String.trim() |> String.to_integer()
    <<data::binary-size(^size), rest::binary>> = rest
    name = name |> String.trim_trailing() |> String.trim_trailing("/")
    read(rest, [{name, data} | acc])
  end
end
