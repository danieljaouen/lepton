defmodule Lepton.Torrent.Magnet do
  @moduledoc """
  Magnet links: `magnet:?xt=urn:btih:HASH&dn=NAME&tr=TRACKER...`. The
  hash is the torrent's info hash, in hex (40 characters) or base32 (32);
  the files' list comes from peers once some are found (BEP 9).
  """

  defstruct [:info_hash, :name, trackers: [], peers: []]

  def magnet?(s), do: String.starts_with?(String.downcase(s), "magnet:?")

  def parse("magnet:?" <> query), do: parse_query(query)
  def parse("MAGNET:?" <> query), do: parse_query(query)
  def parse(_), do: {:error, "not a magnet link"}

  defp parse_query(query) do
    pairs = for part <- String.split(query, "&"), [k, v] <- [String.split(part, "=", parts: 2)], do: {k, URI.decode_www_form(v)}
    hash = Enum.find_value(pairs, fn {k, v} -> String.starts_with?(k, "xt") && decode_hash(v) end)

    if hash do
      {:ok,
       %__MODULE__{
         info_hash: hash,
         name: Enum.find_value(pairs, fn {k, v} -> k == "dn" && v end),
         trackers: for({k, v} <- pairs, String.starts_with?(k, "tr"), do: v) |> Enum.uniq(),
         peers: for({k, v} <- pairs, String.starts_with?(k, "x.pe"), p = peer(v), do: p)
       }}
    else
      {:error, "the magnet link has no BitTorrent hash (xt=urn:btih:...)"}
    end
  end

  defp decode_hash("urn:btih:" <> h) do
    cond do
      byte_size(h) == 40 -> case Base.decode16(h, case: :mixed) do
          {:ok, b} -> b
          _ -> nil
        end

      byte_size(h) == 32 -> case Base.decode32(String.upcase(h)) do
          {:ok, b} -> b
          _ -> nil
        end

      true -> nil
    end
  end

  defp decode_hash(_), do: nil

  defp peer(s) do
    case Regex.run(~r/^\[?([^\]]+?)\]?:(\d+)$/, s, capture: :all_but_first) do
      [h, p] -> {h, String.to_integer(p)}
      _ -> nil
    end
  end

  @doc "A magnet link for a torrent."
  def link(info_hash, name, trackers \\ []) do
    "magnet:?xt=urn:btih:" <> Base.encode16(info_hash, case: :lower) <>
      if(name, do: "&dn=" <> URI.encode_www_form(name), else: "") <>
      Enum.map_join(trackers, "", &("&tr=" <> URI.encode_www_form(&1)))
  end
end
