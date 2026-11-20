defmodule Lepton.IPP do
  @moduledoc """
  The Internet Printing Protocol's messages (RFC 8010): a version, an
  operation (request) or status (response), a request id, groups of
  attributes, then the document data. Printers speak it over HTTP (POST,
  `application/ipp`), and so do CUPS servers.

  A message is `%IPP{code, id, groups, data}`; a group is `{tag,
  [{name, [{value_tag, value}]}]}`. Collections (`media-col`) are kept
  as their raw values, which is all Lepton needs of them.
  """

  defstruct version: {2, 0}, code: 0, id: 1, groups: [], data: ""

  # group delimiters
  @operation 0x01
  @job 0x02
  @end_ 0x03
  @printer 0x04
  @unsupported 0x05

  @tags %{
    0x10 => :unsupported_value, 0x12 => :unknown, 0x13 => :no_value, 0x21 => :integer, 0x22 => :boolean, 0x23 => :enum,
    0x30 => :octet_string, 0x31 => :date_time, 0x32 => :resolution, 0x33 => :range, 0x34 => :beg_collection,
    0x35 => :text_with_language, 0x36 => :name_with_language, 0x37 => :end_collection, 0x41 => :text, 0x42 => :name,
    0x44 => :keyword, 0x45 => :uri, 0x46 => :uri_scheme, 0x47 => :charset, 0x48 => :language, 0x49 => :mime_type,
    0x4A => :member_name
  }
  @codes Map.new(@tags, fn {k, v} -> {v, k} end)

  @groups %{operation: @operation, job: @job, printer: @printer, unsupported: @unsupported}

  def group_tag(name), do: Map.fetch!(@groups, name)

  # -- operations and status codes ------------------------------------------------------------

  @ops %{
    print_job: 0x0002, validate_job: 0x0004, create_job: 0x0005, send_document: 0x0006, cancel_job: 0x0008,
    get_job_attributes: 0x0009, get_jobs: 0x000A, get_printer_attributes: 0x000B,
    cups_get_default: 0x4001, cups_get_printers: 0x4002
  }

  def op(name), do: Map.fetch!(@ops, name)
  def op_name(code), do: Enum.find_value(@ops, code, fn {k, v} -> v == code && k end)

  @status %{ok: 0x0000, bad_request: 0x0400, forbidden: 0x0401, not_found: 0x0406, not_possible: 0x0404,
            document_format_not_supported: 0x040A, operation_not_supported: 0x0501, internal_error: 0x0500, not_accepting: 0x0506}

  def status(name), do: Map.fetch!(@status, name)

  # -- building ----------------------------------------------------------------------------------

  @doc "A request: operation `op` with the usual charset and language first, then `attrs`."
  def request(op, attrs, id \\ 1, more_groups \\ []) do
    head = [{"attributes-charset", [{:charset, "utf-8"}]}, {"attributes-natural-language", [{:language, "en"}]}]
    %__MODULE__{code: op(op), id: id, groups: [{@operation, head ++ attrs} | more_groups]}
  end

  @doc "A response to `req` with status `status`."
  def response(req, status, groups \\ []) do
    head = [{"attributes-charset", [{:charset, "utf-8"}]}, {"attributes-natural-language", [{:language, "en"}]}]
    %__MODULE__{version: req.version, code: status(status), id: req.id, groups: [{@operation, head} | groups]}
  end

  # -- encoding -----------------------------------------------------------------------------------

  def encode(%__MODULE__{version: {ma, mi}} = m) do
    groups =
      for {tag, attrs} <- m.groups do
        [<<tag>>, for({name, values} <- attrs, do: attribute(name, values))]
      end

    IO.iodata_to_binary([<<ma, mi, m.code::16, m.id::32>>, groups, <<@end_>>, m.data])
  end

  defp attribute(name, values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {{tag, value}, i} ->
      n = if i == 0, do: name, else: ""
      bytes = value(tag, value)
      [<<Map.fetch!(@codes, tag), byte_size(n)::16>>, n, <<byte_size(bytes)::16>>, bytes]
    end)
  end

  defp value(t, v) when t in [:integer, :enum], do: <<v::signed-32>>
  defp value(:boolean, v), do: <<if(v, do: 1, else: 0)>>
  defp value(:range, {a, b}), do: <<a::signed-32, b::signed-32>>
  defp value(:resolution, {x, y, units}), do: <<x::32, y::32, units>>
  defp value(t, _) when t in [:no_value, :unknown, :unsupported_value, :beg_collection, :end_collection], do: ""
  defp value(_t, v) when is_binary(v), do: v

  # -- decoding ------------------------------------------------------------------------------------

  def decode(<<ma, mi, code::16, id::32, rest::binary>>) do
    {groups, data} = groups(rest, nil, [], [])
    {:ok, %__MODULE__{version: {ma, mi}, code: code, id: id, groups: groups, data: data}}
  rescue
    _ -> {:error, :malformed}
  end

  def decode(_), do: {:error, :malformed}

  # Delimiter tags (0x00-0x0F) start groups; 0x03 ends the attributes.
  defp groups(<<@end_, data::binary>>, cur, attrs, acc), do: {Enum.reverse(close(cur, attrs, acc)), data}

  defp groups(<<tag, rest::binary>>, cur, attrs, acc) when tag < 0x10 do
    groups(rest, tag, [], close(cur, attrs, acc))
  end

  defp groups(<<tag, nlen::16, name::binary-size(nlen), vlen::16, v::binary-size(vlen), rest::binary>>, cur, attrs, acc) do
    t = Map.get(@tags, tag, :unknown)
    value = decode_value(t, v)

    attrs =
      case {name, attrs} do
        {"", [{n, vs} | more]} -> [{n, vs ++ [{t, value}]} | more]
        _ -> [{name, [{t, value}]} | attrs]
      end

    groups(rest, cur, attrs, acc)
  end

  defp close(nil, _attrs, acc), do: acc
  defp close(tag, attrs, acc), do: [{tag, Enum.reverse(attrs)} | acc]

  defp decode_value(t, <<v::signed-32>>) when t in [:integer, :enum], do: v
  defp decode_value(:boolean, <<b>>), do: b != 0
  defp decode_value(:range, <<a::signed-32, b::signed-32>>), do: {a, b}
  defp decode_value(:resolution, <<x::32, y::32, u>>), do: {x, y, u}
  defp decode_value(_t, v), do: v

  # -- reading ----------------------------------------------------------------------------------------

  @doc "The first value of attribute `name` in group `group` (an atom or tag), or `default`."
  def get(%__MODULE__{groups: groups}, group, name, default \\ nil) do
    tag = if is_atom(group), do: group_tag(group), else: group

    Enum.find_value(groups, default, fn
      {^tag, attrs} -> Enum.find_value(attrs, fn {^name, [{_, v} | _]} -> v; _ -> nil end)
      _ -> nil
    end)
  end

  @doc "All values of `name` in `group`."
  def all(%__MODULE__{groups: groups}, group, name) do
    tag = if is_atom(group), do: group_tag(group), else: group
    for {^tag, attrs} <- groups, {^name, vs} <- attrs, {_, v} <- vs, do: v
  end

  @doc "Each group with tag `group`, as a map of attribute name to values."
  def each(%__MODULE__{groups: groups}, group) do
    tag = if is_atom(group), do: group_tag(group), else: group
    for {^tag, attrs} <- groups, do: Map.new(attrs, fn {n, vs} -> {n, Enum.map(vs, &elem(&1, 1))} end)
  end
end
