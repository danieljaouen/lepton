defmodule Lepton.Wayland.Wire do
  @moduledoc """
  The Wayland wire format.

  A message is a header, the object ID and then `size << 16 | opcode`
  (32-bit words, host byte order), followed by its arguments, each padded
  to 32 bits. File descriptors travel out of band (`SCM_RIGHTS`) in the
  order the `fd` arguments appear. Argument types come from
  `Lepton.Wayland.Protocol`:

    * `:int`, `:uint`, `:object`, `:new_id` - 32-bit words (object 0 is null)
    * `:fixed` - signed 24.8 fixed point; decoded to a float
    * `:string` - length (with the NUL), bytes, NUL, padding; length 0 is null
    * `:array` - length, bytes, padding
    * `{:new_id, nil}` - an untyped new ID (`wl_registry.bind`): interface
      string, version, ID
    * `:fd` - no bytes; taken from the received descriptors
  """

  @doc "Split complete messages off `buf`: `{[{id, opcode, payload}], rest}`."
  def split(buf), do: split(buf, [])

  defp split(<<id::native-32, size::native-16, op::native-16, rest::binary>> = all, acc) when size >= 8 do
    body = size - 8

    case rest do
      <<payload::binary-size(^body), more::binary>> -> split(more, [{id, op, payload} | acc])
      _ -> {Enum.reverse(acc), all}
    end
  end

  defp split(<<_id::native-32, size::native-16, _::native-16, _::binary>>, _acc) when size < 8, do: raise(ArgumentError, "bad message size #{size}")
  defp split(rest, acc), do: {Enum.reverse(acc), rest}

  @doc """
  Decode `payload` against argument `types`, taking `fd` arguments from
  `fds`. Returns `{args, fds_left}`; raises `ArgumentError` on malformed
  input.
  """
  def decode(types, payload, fds), do: decode(types, payload, fds, [])

  defp decode([], <<>>, fds, acc), do: {Enum.reverse(acc), fds}
  defp decode([], _extra, _fds, _acc), do: raise(ArgumentError, "trailing bytes")

  defp decode([t | ts], bin, fds, acc) do
    case {type(t), bin} do
      {:int, <<v::native-signed-32, rest::binary>>} ->
        decode(ts, rest, fds, [v | acc])

      {u, <<v::native-32, rest::binary>>} when u in [:uint, :object, :new_id] ->
        decode(ts, rest, fds, [if(u == :object and v == 0, do: nil, else: v) | acc])

      {:fixed, <<v::native-signed-32, rest::binary>>} ->
        decode(ts, rest, fds, [v / 256 | acc])

      {:string, <<0::native-32, rest::binary>>} ->
        decode(ts, rest, fds, [nil | acc])

      {:string, <<len::native-32, rest::binary>>} ->
        {str, rest} = padded(rest, len)
        decode(ts, rest, fds, [binary_part(str, 0, len - 1) | acc])

      {:array, <<len::native-32, rest::binary>>} ->
        {arr, rest} = padded(rest, len)
        decode(ts, rest, fds, [arr | acc])

      {:untyped, <<len::native-32, rest::binary>>} when len > 0 ->
        {iface, rest} = padded(rest, len)
        <<version::native-32, id::native-32, rest::binary>> = rest
        decode(ts, rest, fds, [{binary_part(iface, 0, len - 1), version, id} | acc])

      {:fd, _} ->
        case fds do
          [fd | more] -> decode(ts, bin, more, [fd | acc])
          [] -> raise ArgumentError, "missing file descriptor"
        end

      _ ->
        raise ArgumentError, "truncated message"
    end
  end

  defp padded(bin, len) do
    pad = rem(4 - rem(len, 4), 4)

    case bin do
      <<data::binary-size(^len), _::binary-size(^pad), rest::binary>> -> {data, rest}
      _ -> raise ArgumentError, "truncated message"
    end
  end

  @doc "Encode a message: `{iodata, fds}` (fds as native-endian 32-bit binaries or integers)."
  def encode(id, opcode, types, args) do
    {body, fds} =
      Enum.zip(types, args)
      |> Enum.reduce({[], []}, fn {t, v}, {acc, fds} ->
        case type(t) do
          :fd -> {acc, [v | fds]}
          ty -> {[acc | arg(ty, v)], fds}
        end
      end)

    size = IO.iodata_length(body) + 8
    {[<<id::native-32, size::native-16, opcode::native-16>> | body], Enum.reverse(fds)}
  end

  defp arg(:int, v), do: <<v::native-signed-32>>
  defp arg(:uint, v), do: <<v::native-32>>
  defp arg(:new_id, v), do: <<v::native-32>>
  defp arg(:object, nil), do: <<0::native-32>>
  defp arg(:object, v), do: <<v::native-32>>
  defp arg(:fixed, v), do: <<round(v * 256)::native-signed-32>>
  defp arg(:string, nil), do: <<0::native-32>>
  defp arg(:string, s), do: [<<byte_size(s) + 1::native-32>>, s, 0 | pad(byte_size(s) + 1)]
  defp arg(:array, a), do: [<<byte_size(a)::native-32>>, a | pad(byte_size(a))]
  defp arg(:untyped, {iface, version, id}), do: [arg(:string, iface), <<version::native-32, id::native-32>>]

  defp pad(len), do: List.duplicate(0, rem(4 - rem(len, 4), 4))

  defp type({:new_id, nil}), do: :untyped
  defp type({:new_id, _}), do: :new_id
  defp type({:object, _}), do: :object
  defp type(t), do: t
end
