defmodule Lepton.DBus.Wire do
  @moduledoc """
  D-Bus's wire format: values marshalled by a type signature, and
  messages (a header of fields, then the body).

  Values in Elixir: integers for `y n q i u x t h`, booleans for `b`,
  floats for `d`, strings for `s o g`, lists for arrays (`a`), maps for
  dictionaries (`a{...}`), tuples for structs (`(...)`), and
  `{:variant, signature, value}` for variants being sent (variants
  received decode to their value).

  Every value is aligned to its size (8 for structs and dict entries),
  counted from the start of the message; the body starts on an 8-byte
  boundary, so offsets within the body give the same alignment.
  """

  import Bitwise

  # -- signatures --------------------------------------------------------------------------------------

  @doc "A signature as a list of complete types: `\"a{sv}s\"` -> `[{:dict, :s, :v}, :s]`."
  def parse(sig) do
    {types, ""} = parse_seq(sig, [])
    types
  end

  defp parse_seq("", acc), do: {Enum.reverse(acc), ""}
  defp parse_seq(")" <> _ = rest, acc), do: {Enum.reverse(acc), rest}
  defp parse_seq("}" <> _ = rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_seq(sig, acc) do
    {t, rest} = parse_one(sig)
    parse_seq(rest, [t | acc])
  end

  defp parse_one("a{" <> rest) do
    {[k, v], "}" <> rest} = parse_seq(rest, [])
    {{:dict, k, v}, rest}
  end

  defp parse_one("a" <> rest) do
    {t, rest} = parse_one(rest)
    {{:array, t}, rest}
  end

  defp parse_one("(" <> rest) do
    {ts, ")" <> rest} = parse_seq(rest, [])
    {{:struct, ts}, rest}
  end

  defp parse_one(<<c, rest::binary>>) when c in ~c"ybnqiuxtdsoghv", do: {String.to_atom(<<c>>), rest}

  @doc "The signature of a parsed type."
  def sig(types) when is_list(types), do: Enum.map_join(types, &sig/1)
  def sig({:dict, k, v}), do: "a{" <> sig(k) <> sig(v) <> "}"
  def sig({:array, t}), do: "a" <> sig(t)
  def sig({:struct, ts}), do: "(" <> sig(ts) <> ")"
  def sig(t) when is_atom(t), do: Atom.to_string(t)

  defp align_of(t) when t in [:y, :g, :v], do: 1
  defp align_of(t) when t in [:n, :q], do: 2
  defp align_of(t) when t in [:b, :i, :u, :h, :s, :o, {:array, nil}], do: 4
  defp align_of({:array, _}), do: 4
  defp align_of({:dict, _, _}), do: 4
  defp align_of(_), do: 8

  # -- encoding ----------------------------------------------------------------------------------------

  @doc "Marshal `values` by `signature`, starting at offset `pos` (for alignment). Returns iodata's binary."
  def encode(signature, values, pos \\ 0) do
    {bin, _} = enc_seq(parse(signature), values, pos, [])
    bin
  end

  defp enc_seq([], [], pos, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), pos}

  defp enc_seq([t | ts], [v | vs], pos, acc) do
    {bin, pos} = enc(t, v, pos)
    enc_seq(ts, vs, pos, [bin | acc])
  end

  defp pad(pos, a), do: rem(a - rem(pos, a), a)

  defp aligned(pos, a, bin) do
    p = pad(pos, a)
    {<<0::size(p * 8), bin::binary>>, pos + p + byte_size(bin)}
  end

  defp enc(:y, v, pos), do: aligned(pos, 1, <<v::8>>)
  defp enc(:b, v, pos), do: aligned(pos, 4, <<if(v, do: 1, else: 0)::little-32>>)
  defp enc(:n, v, pos), do: aligned(pos, 2, <<v::little-signed-16>>)
  defp enc(:q, v, pos), do: aligned(pos, 2, <<v::little-16>>)
  defp enc(:i, v, pos), do: aligned(pos, 4, <<v::little-signed-32>>)
  defp enc(t, v, pos) when t in [:u, :h], do: aligned(pos, 4, <<v::little-32>>)
  defp enc(:x, v, pos), do: aligned(pos, 8, <<v::little-signed-64>>)
  defp enc(:t, v, pos), do: aligned(pos, 8, <<v::little-64>>)
  defp enc(:d, v, pos), do: aligned(pos, 8, <<v / 1::little-float-64>>)
  defp enc(t, v, pos) when t in [:s, :o], do: aligned(pos, 4, <<byte_size(v)::little-32, v::binary, 0>>)
  defp enc(:g, v, pos), do: aligned(pos, 1, <<byte_size(v)::8, v::binary, 0>>)

  defp enc(:v, {:variant, sig, value}, pos) do
    {s, pos} = enc(:g, sig, pos)
    [t] = parse(sig)
    {b, pos} = enc(t, value, pos)
    {s <> b, pos}
  end

  defp enc({:struct, ts}, v, pos) do
    p = pad(pos, 8)
    {bin, pos} = enc_seq(ts, Tuple.to_list(v), pos + p, [])
    {<<0::size(p * 8), bin::binary>>, pos}
  end

  defp enc({:dict, k, vt}, map, pos), do: enc({:array, {:struct, [k, vt]}}, Enum.map(map, fn {a, b} -> {a, b} end), pos)

  defp enc({:array, t}, list, pos) do
    # length (aligned to 4), then padding to the element's alignment (not counted)
    p = pad(pos, 4)
    start = pos + p + 4
    ep = pad(start, align_of(t))

    {elems, _} =
      Enum.reduce(list, {[], start + ep}, fn v, {acc, at} ->
        {bin, at} = enc(t, v, at)
        {[bin | acc], at}
      end)

    body = IO.iodata_to_binary(Enum.reverse(elems))
    bin = <<0::size(p * 8), byte_size(body)::little-32, 0::size(ep * 8), body::binary>>
    {bin, pos + byte_size(bin)}
  end

  # -- decoding ----------------------------------------------------------------------------------------

  @doc "Unmarshal `bin` (which starts at message offset `pos`) by `signature`: the list of values."
  def decode(signature, bin, pos \\ 0) do
    {values, _} = dec_seq(parse(signature), bin, pos, pos, [])
    values
  end

  # `base` is the message offset of bin's first byte.
  defp dec_seq([], _bin, _base, pos, acc), do: {Enum.reverse(acc), pos}

  defp dec_seq([t | ts], bin, base, pos, acc) do
    {v, pos} = dec(t, bin, base, pos)
    dec_seq(ts, bin, base, pos, [v | acc])
  end

  defp at(bin, base, pos, n), do: binary_part(bin, pos - base, n)

  defp dec(t, bin, base, pos) when t in [:y, :n, :q, :b, :i, :u, :h, :x, :t, :d] do
    size = case t do
      :y -> 1
      t when t in [:n, :q] -> 2
      t when t in [:b, :i, :u, :h] -> 4
      _ -> 8
    end

    pos = pos + pad(pos, size)
    raw = at(bin, base, pos, size)

    v =
      case {t, raw} do
        {:y, <<v>>} -> v
        {:n, <<v::little-signed-16>>} -> v
        {:q, <<v::little-16>>} -> v
        {:b, <<v::little-32>>} -> v != 0
        {:i, <<v::little-signed-32>>} -> v
        {t, <<v::little-32>>} when t in [:u, :h] -> v
        {:x, <<v::little-signed-64>>} -> v
        {:t, <<v::little-64>>} -> v
        {:d, <<v::little-float-64>>} -> v
      end

    {v, pos + size}
  end

  defp dec(t, bin, base, pos) when t in [:s, :o] do
    pos = pos + pad(pos, 4)
    <<len::little-32>> = at(bin, base, pos, 4)
    {at(bin, base, pos + 4, len), pos + 4 + len + 1}
  end

  defp dec(:g, bin, base, pos) do
    <<len>> = at(bin, base, pos, 1)
    {at(bin, base, pos + 1, len), pos + 1 + len + 1}
  end

  defp dec(:v, bin, base, pos) do
    {sig, pos} = dec(:g, bin, base, pos)
    [t] = parse(sig)
    dec(t, bin, base, pos)
  end

  defp dec({:struct, ts}, bin, base, pos) do
    {vs, pos} = dec_seq(ts, bin, base, pos + pad(pos, 8), [])
    {List.to_tuple(vs), pos}
  end

  defp dec({:dict, k, v}, bin, base, pos) do
    {pairs, pos} = dec({:array, {:struct, [k, v]}}, bin, base, pos)
    {Map.new(pairs), pos}
  end

  defp dec({:array, t}, bin, base, pos) do
    pos = pos + pad(pos, 4)
    <<len::little-32>> = at(bin, base, pos, 4)
    start = pos + 4 + pad(pos + 4, align_of(t))
    stop = start + len
    {dec_until(t, bin, base, start, stop, []), stop}
  end

  defp dec_until(_t, _bin, _base, pos, stop, acc) when pos >= stop, do: Enum.reverse(acc)

  defp dec_until(t, bin, base, pos, stop, acc) do
    {v, pos} = dec(t, bin, base, pos)
    dec_until(t, bin, base, pos, stop, [v | acc])
  end

  # -- messages --------------------------------------------------------------------------------------

  @types %{method_call: 1, method_return: 2, error: 3, signal: 4}
  @type_names Map.new(@types, fn {k, v} -> {v, k} end)
  @fields %{path: {1, "o"}, interface: {2, "s"}, member: {3, "s"}, error_name: {4, "s"}, reply_serial: {5, "u"}, destination: {6, "s"}, sender: {7, "s"}, signature: {8, "g"}, unix_fds: {9, "u"}}
  @field_names Map.new(@fields, fn {k, {code, _}} -> {code, k} end)

  @doc """
  A message's bytes. `msg` is `%{type, serial, flags}` plus header fields
  (`path`, `interface`, `member`, `destination`, `reply_serial`,
  `error_name`, `signature`) and `body` (a list of values for `signature`).
  """
  def message(msg) do
    sig = msg[:signature] || ""
    body = if sig == "", do: "", else: encode(sig, msg[:body] || [])

    fields =
      for {name, {code, t}} <- @fields, value = (if name == :signature, do: (sig != "" && sig) || nil, else: msg[name]), value not in [nil, false],
          do: {code, {:variant, t, value}}

    head = <<?l, @types[msg.type], msg[:flags] || 0, 1, byte_size(body)::little-32, msg.serial::little-32>>
    header = head <> encode("a(yv)", [fields], 12)
    p = pad(byte_size(header), 8)
    header <> <<0::size(p * 8)>> <> body
  end

  @doc """
  Split a whole message off the front of `data`: `{:ok, message, rest}`,
  or `:more` when it hasn't all arrived.
  """
  def split(<<?l, type, flags, 1, body_len::little-32, serial::little-32, fields_len::little-32, _::binary>> = data) do
    header_len = 16 + fields_len
    total = header_len + pad(header_len, 8) + body_len

    if byte_size(data) < total do
      :more
    else
      <<msg_bin::binary-size(^total), rest::binary>> = data
      [fields] = decode("a(yv)", binary_part(msg_bin, 12, 4 + fields_len), 12)
      header = Map.new(fields, fn {code, v} -> {Map.get(@field_names, code, code), v} end)
      sig = header[:signature] || ""
      body_at = header_len + pad(header_len, 8)
      body = if sig == "", do: [], else: decode(sig, binary_part(msg_bin, body_at, body_len), 0)
      {:ok, Map.merge(header, %{type: @type_names[type], flags: flags, serial: serial, signature: sig, body: body}), rest}
    end
  end

  def split(<<c, _::binary>>) when c != ?l, do: raise(ArgumentError, "big-endian D-Bus messages aren't supported")
  def split(_), do: :more

  @doc false
  def flag_no_reply, do: 1 <<< 0
end
