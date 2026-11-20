defmodule Lepton.Print.Server do
  @moduledoc """
  `cupsd`: the print queue, and an IPP server on 127.0.0.1:631 as CUPS's
  is, so CUPS's clients find it: `lp` and `lpstat`, and Firefox's print
  dialog (through libcups). It lists the printers added with `lpadmin`
  and those found on the network, takes jobs (Print-Job, or Create-Job
  then Send-Document), and sends each on to its printer
  (`Lepton.Print.print/3`). http://localhost:631/ shows the printers and
  jobs.
  """

  use GenServer
  alias Lepton.{IPP, Print}

  @discover_every 60_000

  def port, do: :persistent_term.get({__MODULE__, :port}, 631)
  def uri, do: "ipp://localhost:#{port()}"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Run the server until told to stop (`cupsd`). Returns 0."
  def run(log, opts \\ []) do
    Process.flag(:trap_exit, true)

    case start_link(Keyword.put(opts, :log, log)) do
      {:ok, pid} ->
        receive do
          {:signal, s} when s in [:term, :int] -> GenServer.stop(pid); 0
          {:EXIT, ^pid, _} -> 1
        end

      {:error, reason} ->
        log.("cupsd: cannot start: #{inspect(reason)}")
        1
    end
  end

  # -- the queue ---------------------------------------------------------------------------------

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 631)

    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}, packet: :http_bin]) do
      {:ok, listen} ->
        {:ok, real} = :inet.port(listen)
        :persistent_term.put({__MODULE__, :port}, real)
        me = self()
        spawn_link(fn -> accept(listen, me) end)
        log = opts[:log] || fn _ -> :ok end
        log.("cupsd: listening on 127.0.0.1:#{real}")
        if opts[:discover] != false, do: send(self(), :discover)
        {:ok, %{jobs: %{}, next: 1, discovered: [], log: log, discover: opts[:discover] != false}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @doc "All printers: added, then found on the network (not shadowing an added one)."
  def printers do
    {added, _} = Print.configured()
    found = if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :discovered), else: []
    added ++ Enum.reject(found, fn f -> Enum.any?(added, &(&1.name == f.name)) end)
  end

  @impl true
  def handle_call(:discovered, _from, st), do: {:reply, st.discovered, st}
  def handle_call(:jobs, _from, st), do: {:reply, st.jobs |> Map.values() |> Enum.sort_by(& &1.id), st}

  def handle_call({:submit, job}, _from, st) do
    job = Map.merge(%{id: st.next, state: 3, reason: "none", created: System.os_time(:second)}, job)
    st = %{st | jobs: Map.put(st.jobs, job.id, job), next: st.next + 1}
    st = if job[:data], do: start_job(st, job.id), else: st
    {:reply, Map.delete(st.jobs[job.id], :data), st}
  end

  def handle_call({:document, id, data, format}, _from, st) do
    case st.jobs[id] do
      %{state: 3} = job ->
        st = %{st | jobs: Map.put(st.jobs, id, Map.merge(job, %{data: data, format: format}))}
        {:reply, :ok, start_job(st, id)}

      nil -> {:reply, {:error, :not_found}, st}
      _ -> {:reply, {:error, :not_possible}, st}
    end
  end

  def handle_call({:cancel, id}, _from, st) do
    case st.jobs[id] do
      %{state: s} = job when s in [3, 4, 5] ->
        if job[:worker], do: Process.exit(job.worker, :kill)
        {:reply, :ok, put_job(st, id, %{state: 7, reason: "job-canceled-by-user", data: nil})}

      nil -> {:reply, {:error, :not_found}, st}
      _ -> {:reply, {:error, :not_possible}, st}
    end
  end

  @impl true
  def handle_cast({:job, id, changes}, st), do: {:noreply, put_job(st, id, changes)}

  @impl true
  def handle_info(:discover, st) do
    me = self()
    spawn(fn -> send(me, {:discovered, Print.discover(2000)}) end)
    {:noreply, st}
  end

  def handle_info({:discovered, found}, st) do
    if st.discover, do: Process.send_after(self(), :discover, @discover_every)
    {:noreply, %{st | discovered: found}}
  end

  def handle_info(_, st), do: {:noreply, st}

  defp put_job(st, id, changes), do: %{st | jobs: Map.update!(st.jobs, id, &Map.merge(&1, changes))}

  # Send the job to its printer, from a process of its own.
  defp start_job(st, id) do
    job = st.jobs[id]
    me = self()
    log = st.log

    worker =
      spawn(fn ->
        result =
          case Enum.find(printers(), &(&1.name == job.printer)) do
            nil -> {:error, "no printer named #{job.printer}"}
            p -> Print.print(p.uri, job.data, name: job.name, user: job.user, copies: job[:copies] || 1)
          end

        case result do
          {:ok, _} ->
            log.("cupsd: job #{id} (#{job.name}) printed on #{job.printer}")
            GenServer.cast(me, {:job, id, %{state: 9, reason: "job-completed-successfully", data: nil}})

          {:error, msg} ->
            log.("cupsd: job #{id} on #{job.printer} failed: #{msg}")
            GenServer.cast(me, {:job, id, %{state: 8, reason: "aborted-by-system", message: msg, data: nil}})
        end
      end)

    put_job(st, id, %{state: 5, worker: worker})
  end

  # -- HTTP ---------------------------------------------------------------------------------------

  defp accept(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, c} ->
        pid = spawn(fn -> receive do: (:go -> connection(c)) end)
        :gen_tcp.controlling_process(c, pid)
        send(pid, :go)
        accept(listen, server)

      _ ->
        :ok
    end
  end

  # Requests until the client closes (libcups keeps the connection open).
  defp connection(sock) do
    with {:ok, method, path, headers} <- read_request(sock),
         {:ok, body} <- read_body(sock, headers) do
      {status, type, reply} = route(method, path, body)
      close? = String.downcase(headers["connection"] || "") == "close"

      :gen_tcp.send(sock, [
        "HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{byte_size(reply)}\r\nServer: Lepton cupsd\r\n",
        if(close?, do: "Connection: close\r\n", else: ""),
        "\r\n",
        reply
      ])

      if close?, do: :gen_tcp.close(sock), else: connection(sock)
    else
      _ -> :gen_tcp.close(sock)
    end
  end

  defp read_request(sock) do
    :inet.setopts(sock, packet: :http_bin)

    case :gen_tcp.recv(sock, 0, 60_000) do
      {:ok, {:http_request, method, {:abs_path, path}, _}} -> headers(sock, method, path, %{})
      {:ok, {:http_request, method, path, _}} -> headers(sock, method, inspect(path), %{})
      _ -> :error
    end
  end

  defp headers(sock, method, path, acc) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(sock, method, path, Map.put(acc, String.downcase(to_string(name)), value))

      {:ok, :http_eoh} ->
        :inet.setopts(sock, packet: :raw)

        # libcups waits briefly for this before sending big requests.
        if String.downcase(acc["expect"] || "") == "100-continue", do: :gen_tcp.send(sock, "HTTP/1.1 100 Continue\r\n\r\n")
        {:ok, to_string(method), path, acc}

      _ ->
        :error
    end
  end

  defp read_body(sock, headers) do
    cond do
      String.downcase(headers["transfer-encoding"] || "") == "chunked" -> chunks(sock, [])
      len = headers["content-length"] -> recv_exact(sock, String.to_integer(len))
      true -> {:ok, ""}
    end
  end

  defp chunks(sock, acc) do
    :inet.setopts(sock, packet: :line)

    with {:ok, line} <- :gen_tcp.recv(sock, 0, 30_000),
         {size, _} <- Integer.parse(String.trim(line), 16) do
      :inet.setopts(sock, packet: :raw)

      if size == 0 do
        # trailers, then the blank line
        :inet.setopts(sock, packet: :line)
        skip_trailers(sock)
        :inet.setopts(sock, packet: :raw)
        {:ok, IO.iodata_to_binary(Enum.reverse(acc))}
      else
        with {:ok, data} <- recv_exact(sock, size), {:ok, _crlf} <- recv_exact(sock, 2), do: chunks(sock, [data | acc])
      end
    else
      _ -> :error
    end
  end

  defp skip_trailers(sock) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, line} when line in ["\r\n", "\n"] -> :ok
      {:ok, _} -> skip_trailers(sock)
      _ -> :ok
    end
  end

  defp recv_exact(_sock, 0), do: {:ok, ""}
  defp recv_exact(sock, n), do: :gen_tcp.recv(sock, n, 60_000)

  defp route("POST", _path, body) do
    case IPP.decode(body) do
      {:ok, req} -> {"200 OK", "application/ipp", IPP.encode(ipp(req))}
      _ -> {"400 Bad Request", "text/plain", "not an IPP request\n"}
    end
  end

  defp route("GET", _path, _), do: {"200 OK", "text/html; charset=utf-8", page()}
  defp route(_, _, _), do: {"405 Method Not Allowed", "text/plain", ""}

  defp page do
    esc = &html/1
    rows = for p <- printers(), do: "<tr><td>#{esc.(p.name)}</td><td>#{esc.(p.info || "")}</td><td>#{esc.(p.uri)}</td><td>#{if p[:discovered], do: "found on the network", else: "added"}</td></tr>"
    jobs = for j <- GenServer.call(__MODULE__, :jobs), do: "<tr><td>#{j.id}</td><td>#{esc.(j.printer)}</td><td>#{esc.(j.name)}</td><td>#{esc.(j.user)}</td><td>#{state_name(j.state)}</td></tr>"

    """
    <!doctype html><html><head><meta charset="utf-8"><title>Lepton printing</title>
    <style>body{font-family:sans-serif;margin:2em}td,th{padding:.2em .8em;text-align:left}</style></head><body>
    <h1>Printers</h1><table><tr><th>Name</th><th>Description</th><th>Address</th><th></th></tr>#{Enum.join(rows)}</table>
    <h1>Jobs</h1><table><tr><th>Id</th><th>Printer</th><th>Title</th><th>User</th><th>State</th></tr>#{Enum.join(jobs)}</table>
    </body></html>
    """
  end

  # -- IPP ---------------------------------------------------------------------------------------

  defp ipp(req) do
    case IPP.op_name(req.code) do
      :cups_get_printers ->
        IPP.response(req, :ok, for(p <- printers(), do: {IPP.group_tag(:printer), printer_attrs(p)}))

      :cups_get_default ->
        {_, d} = Print.configured()
        ps = printers()

        case Enum.find(ps, &(&1.name == d)) || List.first(ps) do
          nil -> IPP.response(req, :not_found)
          p -> IPP.response(req, :ok, [{IPP.group_tag(:printer), printer_attrs(p)}])
        end

      :get_printer_attributes ->
        with_printer(req, fn p -> IPP.response(req, :ok, [{IPP.group_tag(:printer), printer_attrs(p)}]) end)

      :validate_job ->
        with_printer(req, fn _ -> IPP.response(req, :ok) end)

      op when op in [:print_job, :create_job] ->
        with_printer(req, fn p ->
          job = %{printer: p.name, name: IPP.get(req, :operation, "job-name", "Untitled"), user: IPP.get(req, :operation, "requesting-user-name", "anonymous"),
                  copies: IPP.get(req, :job, "copies", 1), format: IPP.get(req, :operation, "document-format", "application/octet-stream")}
          job = if op == :print_job, do: Map.put(job, :data, req.data), else: job
          job = GenServer.call(__MODULE__, {:submit, job})
          IPP.response(req, :ok, [{IPP.group_tag(:job), job_attrs(job)}])
        end)

      :send_document ->
        id = job_id(req)

        case GenServer.call(__MODULE__, {:document, id, req.data, IPP.get(req, :operation, "document-format")}) do
          :ok -> IPP.response(req, :ok, [{IPP.group_tag(:job), job_attrs(find_job(id))}])
          {:error, s} -> IPP.response(req, s)
        end

      :get_jobs ->
        which = IPP.get(req, :operation, "which-jobs", "not-completed")
        printer = printer_name(req)

        jobs =
          for j <- GenServer.call(__MODULE__, :jobs), printer in [nil, j.printer],
              (which == "all") or (which == "completed" and j.state >= 7) or (which == "not-completed" and j.state < 7),
              do: {IPP.group_tag(:job), job_attrs(j)}

        IPP.response(req, :ok, jobs)

      :get_job_attributes ->
        case find_job(job_id(req)) do
          nil -> IPP.response(req, :not_found)
          j -> IPP.response(req, :ok, [{IPP.group_tag(:job), job_attrs(j)}])
        end

      :cancel_job ->
        case GenServer.call(__MODULE__, {:cancel, job_id(req)}) do
          :ok -> IPP.response(req, :ok)
          {:error, s} -> IPP.response(req, s)
        end

      _ ->
        IPP.response(req, :operation_not_supported)
    end
  end

  defp printer_name(req) do
    case IPP.get(req, :operation, "printer-uri") do
      nil -> nil
      uri -> case Regex.run(~r{/printers/([^/?]+)}, uri) do [_, n] -> URI.decode(n); _ -> nil end
    end
  end

  defp with_printer(req, fun) do
    name = printer_name(req)

    case name && Enum.find(printers(), &(&1.name == name)) do
      nil -> IPP.response(req, :not_found)
      p -> fun.(p)
    end
  end

  defp job_id(req) do
    IPP.get(req, :operation, "job-id") ||
      case IPP.get(req, :operation, "job-uri") do
        nil -> nil
        uri -> case Regex.run(~r{/jobs/(\d+)}, uri) do [_, n] -> String.to_integer(n); _ -> nil end
      end
  end

  defp find_job(id), do: Enum.find(GenServer.call(__MODULE__, :jobs), &(&1.id == id))

  defp printer_attrs(p) do
    jobs = GenServer.call(__MODULE__, :jobs)
    busy = Enum.any?(jobs, &(&1.printer == p.name and &1.state == 5))
    queued = Enum.count(jobs, &(&1.printer == p.name and &1.state < 7))

    [
      {"printer-uri-supported", [{:uri, "#{uri()}/printers/#{URI.encode(p.name)}"}]},
      {"uri-authentication-supported", [{:keyword, "none"}]},
      {"uri-security-supported", [{:keyword, "none"}]},
      {"printer-name", [{:name, p.name}]},
      {"printer-info", [{:text, if(p[:info] in [nil, ""], do: p.name, else: p.info)}]},
      {"printer-location", [{:text, p[:location] || ""}]},
      {"printer-make-and-model", [{:text, p[:model] || "IPP Everywhere"}]},
      {"printer-state", [{:enum, if(busy, do: 4, else: 3)}]},
      {"printer-state-reasons", [{:keyword, "none"}]},
      {"printer-is-accepting-jobs", [{:boolean, true}]},
      {"printer-is-shared", [{:boolean, false}]},
      {"printer-type", [{:enum, 0x0400_8044}]},
      {"queued-job-count", [{:integer, queued}]},
      {"device-uri", [{:uri, p.uri}]},
      {"printer-more-info", [{:uri, "http://localhost:#{port()}/"}]},
      {"document-format-supported", [{:mime_type, "application/pdf"}, {:mime_type, "text/plain"}, {:mime_type, "image/jpeg"}, {:mime_type, "application/octet-stream"}]},
      {"document-format-default", [{:mime_type, "application/octet-stream"}]},
      {"copies-supported", [{:range, {1, 99}}]},
      {"copies-default", [{:integer, 1}]},
      {"media-default", [{:keyword, "iso_a4_210x297mm"}]},
      {"media-supported", [{:keyword, "iso_a4_210x297mm"}, {:keyword, "na_letter_8.5x11in"}]},
      {"sides-supported", [{:keyword, "one-sided"}]},
      {"sides-default", [{:keyword, "one-sided"}]},
      {"print-color-mode-supported", [{:keyword, "auto"}, {:keyword, "color"}, {:keyword, "monochrome"}]},
      {"print-color-mode-default", [{:keyword, "auto"}]},
      {"charset-configured", [{:charset, "utf-8"}]},
      {"charset-supported", [{:charset, "utf-8"}]},
      {"natural-language-configured", [{:language, "en"}]},
      {"generated-natural-language-supported", [{:language, "en"}]},
      {"ipp-versions-supported", [{:keyword, "1.1"}, {:keyword, "2.0"}]},
      {"operations-supported", Enum.map([0x0002, 0x0004, 0x0005, 0x0006, 0x0008, 0x0009, 0x000A, 0x000B, 0x4001, 0x4002], &{:enum, &1})},
      {"compression-supported", [{:keyword, "none"}]},
      {"pdl-override-supported", [{:keyword, "not-attempted"}]},
      {"printer-up-time", [{:integer, System.os_time(:second)}]}
    ]
  end

  defp job_attrs(j) do
    [
      {"job-id", [{:integer, j.id}]},
      {"job-uri", [{:uri, "#{uri()}/jobs/#{j.id}"}]},
      {"job-printer-uri", [{:uri, "#{uri()}/printers/#{URI.encode(j.printer)}"}]},
      {"job-name", [{:name, j.name}]},
      {"job-originating-user-name", [{:name, j.user}]},
      {"job-state", [{:enum, j.state}]},
      {"job-state-reasons", [{:keyword, j.reason}]},
      {"time-at-creation", [{:integer, j.created}]}
    ] ++ if(j[:message], do: [{"job-printer-state-message", [{:text, j.message}]}], else: [])
  end

  @doc false
  def state_name(3), do: "pending"
  def state_name(4), do: "held"
  def state_name(5), do: "printing"
  def state_name(6), do: "stopped"
  def state_name(7), do: "canceled"
  def state_name(8), do: "aborted"
  def state_name(9), do: "completed"
  def state_name(_), do: "unknown"

  defp html(s), do: s |> to_string() |> String.replace("&", "&amp;") |> String.replace("<", "&lt;") |> String.replace(">", "&gt;") |> String.replace("\"", "&quot;")
end
