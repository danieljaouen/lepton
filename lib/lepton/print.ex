defmodule Lepton.Print do
  @moduledoc """
  Printing: the printers, and talking to them.

  Lepton prints to network printers by IPP (driverless: AirPrint and IPP
  Everywhere printers, which most printers made since about 2012 are),
  sending PDF, JPEG or text made into PDF. Printers are added with
  `lpadmin` (kept in `/var/lib/lepton/printers`), or found on the
  network by mDNS (`discover/1`) and usable without adding, as CUPS's
  temporary queues are. Each user's default printer is the `Default`
  line of `~/.cups/lpoptions`, the file CUPS's own library reads (so
  Firefox agrees); the system's is `lpadmin -d`.

  `Lepton.Print.Server` (`cupsd`) is the queue, and an IPP server on
  127.0.0.1:631 as CUPS's is, so `lp`, `lpstat` and Firefox's print
  dialog all go through it.
  """

  alias Lepton.IPP

  # -- the printers ----------------------------------------------------------------------------

  defp config_path, do: Lepton.Persist.state_path("printers")

  @doc "The printers added with lpadmin: `[%{name, uri, info, location}]`, and the system default."
  def configured do
    case File.read(config_path()) do
      {:ok, text} ->
        lines = String.split(text, "\n", trim: true)

        printers =
          for "printer " <> rest <- lines, [name, uri | more] <- [String.split(rest, " ", parts: 3)] do
            {info, location} =
              case more do
                [extra] -> case String.split(extra, "\t", parts: 2) do [i, l] -> {i, l}; [i] -> {i, ""} end
                [] -> {"", ""}
              end

            %{name: name, uri: uri, info: info, location: location, discovered: false}
          end

        default = Enum.find_value(lines, fn "default " <> n -> String.trim(n); _ -> nil end)
        {printers, default}

      _ ->
        {[], nil}
    end
  end

  defp save({printers, default}) do
    text =
      Enum.map_join(printers, "", &"printer #{&1.name} #{&1.uri} #{&1.info}\t#{&1.location}\n") <>
        if(default, do: "default #{default}\n", else: "")

    File.mkdir_p!(Path.dirname(config_path()))
    File.write!(config_path(), text)
  end

  def valid_name?(name), do: Regex.match?(~r/^[A-Za-z0-9_.-]{1,127}$/, name)

  def add(name, uri, info \\ "", location \\ "") do
    cond do
      not valid_name?(name) -> {:error, "#{name}: a printer's name is letters, digits, _ . and -"}
      not String.match?(uri, ~r/^(ipps?|https?):\/\//) -> {:error, "#{uri}: printers are reached by ipp://, ipps://, http:// or https:// URIs"}
      true ->
        {ps, d} = configured()
        save({Enum.reject(ps, &(&1.name == name)) ++ [%{name: name, uri: uri, info: info, location: location}], d})
        :ok
    end
  end

  def delete(name) do
    {ps, d} = configured()

    if Enum.any?(ps, &(&1.name == name)),
      do: (save({Enum.reject(ps, &(&1.name == name)), if(d == name, do: nil, else: d)}); :ok),
      else: {:error, "#{name}: no such printer"}
  end

  def set_system_default(name) do
    {ps, _} = configured()
    save({ps, name})
  end

  @doc "A user's default (from `~/.cups/lpoptions`), else the system's."
  def default(home) do
    lpoptions =
      case File.read(Path.join(home, ".cups/lpoptions")) do
        {:ok, text} -> Enum.find_value(String.split(text, "\n"), fn line -> case String.split(line) do ["Default", n | _] -> n; _ -> nil end end)
        _ -> nil
      end

    lpoptions || elem(configured(), 1)
  end

  @doc "Make `name` the user's default (in `~/.cups/lpoptions`)."
  def set_default(home, name) do
    path = Path.join(home, ".cups/lpoptions")
    old = case File.read(path) do {:ok, t} -> String.split(t, "\n", trim: true); _ -> [] end
    kept = Enum.reject(old, &String.starts_with?(&1, "Default "))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.join(["Default #{name}" | kept], "\n") <> "\n")
  end

  # -- IPP to a printer ------------------------------------------------------------------------

  @doc "Send an IPP request to `uri` (`ipp://`, `ipps://`): `{:ok, response}` or `{:error, reason}`."
  def call(uri, %IPP{} = req, timeout \\ 30_000) do
    url =
      uri
      |> String.replace(~r/^ipp:\/\/([^\/:]+)(?=\/|$)/, "http://\\1:631")
      |> String.replace(~r/^ipps:\/\/([^\/:]+)(?=\/|$)/, "https://\\1:631")
      |> String.replace_prefix("ipp://", "http://")
      |> String.replace_prefix("ipps://", "https://")

    :inets.start()
    :ssl.start()

    # Printers' certificates are their own (self-signed).
    case :httpc.request(:post, {String.to_charlist(url), [], ~c"application/ipp", IPP.encode(req)}, [ssl: [verify: :verify_none], timeout: timeout, connect_timeout: 10_000], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> IPP.decode(body)
      {:ok, {{_, code, reason}, _, _}} -> {:error, "HTTP #{code} #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A printer's attributes (`get_printer_attributes`)."
  def attributes(uri) do
    req = IPP.request(:get_printer_attributes, [{"printer-uri", [{:uri, uri}]}, {"requested-attributes", [{:keyword, "all"}]}])

    with {:ok, resp} <- call(uri, req, 15_000) do
      if resp.code < 0x100, do: {:ok, resp}, else: {:error, "the printer answered status 0x#{Integer.to_string(resp.code, 16)}"}
    end
  end

  @doc """
  Send `data` to the printer at `uri` (Print-Job). Text becomes PDF; PDF
  and JPEG go as they are, if the printer takes them. Options: `:name`,
  `:user`, `:copies`. Returns `{:ok, printer_job_id}` or `{:error, msg}`.
  """
  def print(uri, data, opts \\ []) do
    with {:ok, attrs} <- attributes(uri),
         supported = IPP.all(attrs, :printer, "document-format-supported"),
         media = IPP.get(attrs, :printer, "media-default", "iso_a4_210x297mm"),
         {:ok, format, doc} <- prepare(data, supported, media) do
      job = if (opts[:copies] || 1) > 1, do: [{IPP.group_tag(:job), [{"copies", [{:integer, opts[:copies]}]}]}], else: []

      req =
        IPP.request(:print_job, [
          {"printer-uri", [{:uri, uri}]},
          {"requesting-user-name", [{:name, opts[:user] || "lepton"}]},
          {"job-name", [{:name, opts[:name] || "Lepton"}]},
          {"document-format", [{:mime_type, format}]}
        ], 1, job)

      case call(uri, %{req | data: doc}, 120_000) do
        {:ok, %IPP{code: c} = r} when c < 0x100 -> {:ok, IPP.get(r, :job, "job-id")}
        {:ok, %IPP{code: c} = r} -> {:error, IPP.get(r, :operation, "status-message") || "the printer refused the job (0x#{Integer.to_string(c, 16)})"}
        {:error, e} -> {:error, if(is_binary(e), do: e, else: inspect(e))}
      end
    end
  end

  @doc "What `data` is: a MIME type."
  def format(<<"%PDF", _::binary>>), do: "application/pdf"
  def format(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def format(<<0x89, "PNG", _::binary>>), do: "image/png"
  def format(<<"%!", _::binary>>), do: "application/postscript"
  def format(data), do: if(String.valid?(data), do: "text/plain", else: "application/octet-stream")

  # The format to send, and the document in it.
  defp prepare(data, supported, media) do
    fmt = format(data)

    cond do
      fmt == "text/plain" and "application/pdf" in supported -> {:ok, "application/pdf", pdf(data, media)}
      fmt == "text/plain" and "text/plain" in supported -> {:ok, "text/plain", data}
      fmt in supported -> {:ok, fmt, data}
      "application/octet-stream" in supported and fmt != "text/plain" -> {:ok, "application/octet-stream", data}
      true -> {:error, "the printer can't print #{fmt} (it takes: #{Enum.join(supported, ", ")}); Lepton sends PDF, JPEG or text"}
    end
  end

  # -- discovery (mDNS / DNS-SD) -----------------------------------------------------------------

  @services ["_ipp._tcp.local", "_ipps._tcp.local"]

  @doc """
  The IPP printers on the network, as `[%{name, uri, info, model}]`, from
  their mDNS answers within `timeout` ms.
  """
  def discover(timeout \\ 2000) do
    case :gen_udp.open(0, [:binary, active: false, multicast_ttl: 255, multicast_loop: true]) do
      {:ok, sock} ->
        try do
          :gen_udp.send(sock, {224, 0, 0, 251}, 5353, query(@services))
          deadline = System.monotonic_time(:millisecond) + timeout
          records = collect(sock, deadline, [])
          printers(records)
        after
          :gen_udp.close(sock)
        end

      _ ->
        []
    end
  end

  defp collect(sock, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)

    if left <= 0 do
      acc
    else
      case :gen_udp.recv(sock, 0, left) do
        {:ok, {_ip, _port, packet}} -> collect(sock, deadline, acc ++ records(packet))
        _ -> acc
      end
    end
  end

  @doc false
  # A DNS query for PTR records, asking for unicast answers (the QU bit).
  def query(names) do
    qs = for n <- names, do: [labels(n), <<12::16, 0x8001::16>>]
    IO.iodata_to_binary([<<0::16, 0::16, length(names)::16, 0::16, 0::16, 0::16>>, qs])
  end

  defp labels(name), do: [for(l <- String.split(name, "."), do: [<<byte_size(l)>>, l]), <<0>>]

  @doc false
  # The resource records of a DNS message: `[{type, name, data}]`.
  def records(<<_id::16, _flags::16, qd::16, an::16, ns::16, ar::16, _::binary>> = msg) do
    {_, off} = Enum.reduce(1..qd//1, {nil, 12}, fn _, {_, off} -> {_, off} = name(msg, off); {nil, off + 4} end)

    {recs, _} =
      Enum.reduce(1..(an + ns + ar)//1, {[], off}, fn _, {acc, off} ->
        {n, off} = name(msg, off)
        <<_::binary-size(^off), type::16, _class::16, _ttl::32, len::16, rdata::binary-size(len), _::binary>> = msg
        {[rr(type, n, msg, off + 10, rdata) | acc], off + 10 + len}
      end)

    Enum.reverse(recs)
  rescue
    _ -> []
  end

  def records(_), do: []

  defp rr(1, n, _msg, _off, <<a, b, c, d>>), do: {:a, n, {a, b, c, d}}
  defp rr(12, n, msg, off, _), do: {:ptr, n, elem(name(msg, off), 0)}
  defp rr(33, n, msg, off, <<_prio::16, _weight::16, port::16, _::binary>>), do: {:srv, n, {elem(name(msg, off + 6), 0), port}}

  defp rr(16, n, _msg, _off, rdata) do
    kv = for <<len, s::binary-size(len) <- rdata>>, [k, v] <- [String.split(s, "=", parts: 2) ++ [""]] |> Enum.map(&Enum.take(&1, 2)), into: %{}, do: {String.downcase(k), v}
    {:txt, n, kv}
  end

  defp rr(type, n, _, _, data), do: {type, n, data}

  # A (possibly compressed) name at `off`: `{name, offset after it}`.
  defp name(msg, off), do: name(msg, off, [], nil)

  defp name(msg, off, acc, after_ptr) do
    case msg do
      <<_::binary-size(^off), 0, _::binary>> ->
        {acc |> Enum.reverse() |> Enum.join("."), after_ptr || off + 1}

      <<_::binary-size(^off), 3::2, ptr::14, _::binary>> ->
        name(msg, ptr, acc, after_ptr || off + 2)

      <<_::binary-size(^off), len, label::binary-size(len), _::binary>> ->
        name(msg, off + 1 + len, [label | acc], after_ptr)
    end
  end

  @doc false
  def printers(records) do
    instances = for {:ptr, svc, inst} <- records, svc in @services, uniq: true, do: inst
    addrs = for {:a, host, ip} <- records, into: %{}, do: {String.downcase(host), ip}

    for inst <- instances,
        {:srv, ^inst, {host, port}} <- Enum.take(for(r = {:srv, ^inst, _} <- records, do: r), 1) do
      txt = Enum.find_value(records, %{}, fn {:txt, ^inst, kv} -> kv; _ -> nil end)
      label = inst |> String.split("._ip") |> hd() |> String.replace(~r/\\(\d{3})/, fn _ -> " " end)
      ip = Map.get(addrs, String.downcase(host))
      where = if ip, do: :inet.ntoa(ip) |> to_string(), else: host
      scheme = if String.contains?(inst, "._ipps."), do: "ipps", else: "ipp"
      rp = Map.get(txt, "rp", "ipp/print")

      %{name: label |> String.replace(~r/[^A-Za-z0-9_.-]+/, "_") |> String.trim("_"), uri: "#{scheme}://#{where}:#{port}/#{rp}",
        info: label, model: Map.get(txt, "ty", ""), discovered: true}
    end
    |> Enum.uniq_by(& &1.name)
  end

  # -- text to PDF ------------------------------------------------------------------------------

  @doc """
  `text` as a PDF: Courier 10 point, wrapped at the margins, on A4 or
  US Letter (from the printer's `media-default`).
  """
  def pdf(text, media \\ "iso_a4_210x297mm") do
    {w, h} = if String.contains?(media, "letter"), do: {612, 792}, else: {595, 842}
    cols = div(w - 72, 6)
    rows = div(h - 72, 12)

    lines =
      text
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        line = expand_tabs(line)
        if line == "", do: [""], else: line |> String.graphemes() |> Enum.chunk_every(cols) |> Enum.map(&Enum.join/1)
      end)
      |> then(fn ls -> if List.last(ls) == "", do: Enum.drop(ls, -1), else: ls end)

    pages = if lines == [], do: [[]], else: Enum.chunk_every(lines, rows)
    n = length(pages)

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [#{Enum.map_join(0..(n - 1), " ", &"#{4 + 2 * &1} 0 R")}] /Count #{n} >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>"
      ] ++
        Enum.flat_map(Enum.with_index(pages), fn {page, i} ->
          stream = "BT /F1 10 Tf 12 TL 36 #{h - 36 - 10} Td\n" <> Enum.map_join(page, "\n", &"(#{pdf_string(&1)}) Tj T*") <> "\nET"

          ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{w} #{h}] /Resources << /Font << /F1 3 0 R >> >> /Contents #{5 + 2 * i} 0 R >>",
           "<< /Length #{byte_size(stream)} >>\nstream\n#{stream}\nendstream"]
        end)

    header = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n"

    {body, offsets} =
      objects
      |> Enum.with_index(1)
      |> Enum.reduce({header, []}, fn {obj, i}, {acc, offs} -> {acc <> "#{i} 0 obj\n#{obj}\nendobj\n", [byte_size(acc) | offs]} end)

    xref_at = byte_size(body)
    xref = "xref\n0 #{length(objects) + 1}\n0000000000 65535 f \n" <> Enum.map_join(Enum.reverse(offsets), "", &(String.pad_leading(to_string(&1), 10, "0") <> " 00000 n \n"))
    body <> xref <> "trailer\n<< /Size #{length(objects) + 1} /Root 1 0 R >>\nstartxref\n#{xref_at}\n%%EOF\n"
  end

  defp expand_tabs(line) do
    line
    |> String.split("\t")
    |> Enum.reduce("", fn part, acc -> if acc == "", do: part, else: acc <> String.duplicate(" ", 8 - rem(String.length(acc), 8)) <> part end)
  end

  # PDF string bytes: WinAnsi (Latin-1) where it can, `?` elsewhere.
  defp pdf_string(s) do
    for <<c::utf8 <- s>>, into: "" do
      cond do
        c in [?(, ?), ?\\] -> <<?\\, c>>
        c < 32 -> " "
        c < 256 -> <<c>>
        true -> "?"
      end
    end
  end
end
