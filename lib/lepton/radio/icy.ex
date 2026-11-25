defmodule Lepton.Radio.ICY do
  @moduledoc """
  An internet radio stream, read the way players do (SHOUTcast, Icecast):
  an HTTP request asking for in-stream titles (`Icy-MetaData: 1`). The
  server then puts a metadata block (`StreamTitle='Artist - Song';`)
  every `icy-metaint` bytes of audio; they are taken out, so that ffmpeg
  gets the sound alone, and each new title is reported. (ffmpeg reads the
  title a stream starts with, not the next ones.)

  Redirects are followed; playlists (`.pls`, `.m3u`) give the stream
  they list. HLS (`.m3u8` with `#EXT-X-` lines) is handed back to ffmpeg,
  which reads it itself.
  """

  @max_redirects 5

  @doc """
  Read `url` until the connection ends or the process is stopped: audio
  goes to `sink.(binary)`, titles to `notify.({:title, text})` and the
  station's own name to `notify.({:name, text})`. Returns `{:hls, url}`
  for a stream ffmpeg should read itself, `:done`, or `{:error, message}`.
  """
  def run(url, sink, notify, env \\ %{}), do: run(url, sink, notify, env, @max_redirects)

  defp run(_url, _sink, _notify, _env, 0), do: {:error, "too many redirects"}

  defp run(url, sink, notify, env, left) do
    with {:ok, conn, status, headers, rest} <- request(url, env) do
      type = (headers["content-type"] || "") |> String.downcase() |> String.split(";") |> hd() |> String.trim()

      cond do
        status in 300..399 and headers["location"] ->
          close(conn)
          run(URI.merge(url, headers["location"]) |> to_string(), sink, notify, env, left - 1)

        status not in 200..299 ->
          close(conn)
          {:error, "the station answered #{status}"}

        playlist?(type, url) ->
          body = read_all(conn, rest, 256 * 1024)
          close(conn)

          case playlist(body, url) do
            {:hls, u} -> {:hls, u}
            {:stream, u} -> run(u, sink, notify, env, left - 1)
            :none -> {:error, "an empty playlist"}
          end

        String.starts_with?(type, "text/html") ->
          close(conn)
          {:error, "that address is a web page, not a stream"}

        true ->
          if headers["icy-name"], do: notify.({:name, headers["icy-name"]})
          metaint = headers["icy-metaint"] && String.to_integer(String.trim(headers["icy-metaint"]))
          stream(conn, rest, metaint, sink, notify)
      end
    end
  end

  defp playlist?(type, url) do
    type in ["audio/x-scpls", "audio/scpls", "audio/x-mpegurl", "audio/mpegurl", "application/x-mpegurl", "application/vnd.apple.mpegurl", "application/pls+xml"] or
      (type in ["text/plain", "application/octet-stream", ""] and Path.extname(URI.parse(url).path || "") in [".pls", ".m3u", ".m3u8"])
  end

  @doc """
  The stream a playlist names: `{:stream, url}`, `{:hls, url}` (an HLS
  playlist: ffmpeg reads it), or `:none`.
  """
  def playlist(body, base) do
    lines = body |> String.split(~r/\r?\n/) |> Enum.map(&String.trim/1)

    cond do
      Enum.any?(lines, &String.starts_with?(&1, "#EXT-X-")) ->
        {:hls, base}

      Enum.any?(lines, &(&1 =~ ~r/^\[playlist\]$/i)) ->
        case Enum.find_value(lines, &(Regex.run(~r/^File\d+=(.+)$/i, &1, capture: :all_but_first))) do
          [u] -> {:stream, URI.merge(base, u) |> to_string()}
          _ -> :none
        end

      true ->
        case Enum.find(lines, &(&1 != "" and not String.starts_with?(&1, "#"))) do
          nil -> :none
          u -> {:stream, URI.merge(base, u) |> to_string()}
        end
    end
  end

  # -- the stream ------------------------------------------------------------------------------

  defp stream(conn, rest, nil, sink, _notify) do
    if rest != "", do: sink.(rest)
    pipe(conn, sink)
  end

  defp stream(conn, rest, metaint, sink, notify), do: audio(conn, rest, metaint, metaint, sink, notify)

  defp pipe(conn, sink) do
    case recv(conn) do
      {:ok, data} -> sink.(data); pipe(conn, sink)
      :closed -> :done
      {:error, why} -> {:error, why}
    end
  end

  # `left` bytes of audio until the next metadata block.
  defp audio(conn, buf, left, metaint, sink, notify) do
    cond do
      byte_size(buf) >= left ->
        <<sound::binary-size(^left), more::binary>> = buf
        if sound != "", do: sink.(sound)
        meta(conn, more, metaint, sink, notify)

      true ->
        if buf != "", do: sink.(buf)

        case recv(conn) do
          {:ok, data} -> audio(conn, data, left - byte_size(buf), metaint, sink, notify)
          :closed -> :done
          {:error, why} -> {:error, why}
        end
    end
  end

  # A length byte (blocks of 16), then the metadata.
  defp meta(conn, <<>>, metaint, sink, notify) do
    case recv(conn) do
      {:ok, data} -> meta(conn, data, metaint, sink, notify)
      :closed -> :done
      {:error, why} -> {:error, why}
    end
  end

  defp meta(conn, <<n, more::binary>>, metaint, sink, notify) do
    case take(conn, more, n * 16) do
      {:ok, block, rest} ->
        if block != "", do: (case title(block) do
          nil -> :ok
          t -> notify.({:title, t})
        end)

        audio(conn, rest, metaint, metaint, sink, notify)

      other ->
        other
    end
  end

  defp take(_conn, buf, n) when byte_size(buf) >= n do
    <<block::binary-size(^n), rest::binary>> = buf
    {:ok, block, rest}
  end

  defp take(conn, buf, n) do
    case recv(conn) do
      {:ok, data} -> take(conn, buf <> data, n)
      :closed -> :done
      {:error, why} -> {:error, why}
    end
  end

  @doc "The title in a metadata block (`StreamTitle='...';`), or nil when it has none."
  def title(block) do
    text = block |> String.trim_trailing(<<0>>) |> to_utf8()

    case Regex.run(~r/StreamTitle='(.*?)';/s, text, capture: :all_but_first) do
      [t] -> if String.trim(t) == "", do: nil, else: String.trim(t)
      _ -> nil
    end
  end

  # Titles come in UTF-8, or (older servers) Latin-1.
  defp to_utf8(bin) do
    if String.valid?(bin), do: bin, else: :unicode.characters_to_binary(bin, :latin1)
  end

  # -- HTTP ----------------------------------------------------------------------------------------

  # HTTP/1.0: no chunked replies to undo. Returns the connection, the
  # status, the headers (lower-case names) and what came after them.
  defp request(url, env) do
    uri = URI.parse(url)

    with true <- uri.scheme in ["http", "https"] || {:error, "not a web address: #{url}"},
         host when is_binary(host) <- uri.host || {:error, "no host in #{url}"},
         port = uri.port || if(uri.scheme == "https", do: 443, else: 80),
         {:ok, tcp} <- Lepton.Proxy.connect(host, port, Lepton.Proxy.chain(host, String.to_atom(uri.scheme), env)),
         {:ok, conn} <- secure(tcp, uri.scheme, host),
         path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: ""),
         :ok <- send_req(conn, "GET #{path} HTTP/1.0\r\nHost: #{host}\r\nUser-Agent: Lepton-Radio/1.0\r\nAccept: */*\r\nIcy-MetaData: 1\r\nConnection: close\r\n\r\n"),
         {:ok, head, rest} <- read_head(conn, "") do
      [status_line | lines] = String.split(head, "\r\n")
      status = case Regex.run(~r/^(?:HTTP\/\d\.\d|ICY)\s+(\d{3})/, status_line, capture: :all_but_first) do
        [s] -> String.to_integer(s)
        _ -> 0
      end

      headers =
        for l <- lines, [k, v] <- [String.split(l, ":", parts: 2)], into: %{} do
          {String.downcase(String.trim(k)), String.trim(v)}
        end

      {:ok, conn, status, headers, rest}
    else
      {:error, why} when is_binary(why) -> {:error, why}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  defp secure(tcp, "https", host) do
    opts = Lepton.Git.Remote.ssl_opts([]) ++ [server_name_indication: String.to_charlist(host), active: false, mode: :binary]

    case :ssl.connect(tcp, opts, 20_000) do
      {:ok, s} -> {:ok, {:ssl, s}}
      {:error, why} -> {:error, "TLS with #{host}: #{inspect(why)}"}
    end
  end

  defp secure(tcp, _, _host), do: {:ok, {:tcp, tcp}}

  defp send_req({:ssl, s}, data), do: :ssl.send(s, data)
  defp send_req({:tcp, s}, data), do: :gen_tcp.send(s, data)

  defp recv(conn) do
    result = case conn do
      {:ssl, s} -> :ssl.recv(s, 0, 30_000)
      {:tcp, s} -> :gen_tcp.recv(s, 0, 30_000)
    end

    case result do
      {:ok, data} -> {:ok, data}
      {:error, :closed} -> :closed
      {:error, :timeout} -> {:error, "the station stopped sending"}
      {:error, why} -> {:error, inspect(why)}
    end
  end

  defp close({:ssl, s}), do: :ssl.close(s)
  defp close({:tcp, s}), do: :gen_tcp.close(s)

  defp read_head(conn, buf) do
    case :binary.match(buf, "\r\n\r\n") do
      {at, 4} ->
        {:ok, binary_part(buf, 0, at), binary_part(buf, at + 4, byte_size(buf) - at - 4)}

      :nomatch when byte_size(buf) > 64 * 1024 ->
        {:error, "the station's reply has no end of headers"}

      :nomatch ->
        case recv(conn) do
          {:ok, data} -> read_head(conn, buf <> data)
          :closed -> {:error, "the station closed the connection"}
          other -> other
        end
    end
  end

  defp read_all(conn, buf, max) when byte_size(buf) < max do
    case recv(conn) do
      {:ok, data} -> read_all(conn, buf <> data, max)
      _ -> buf
    end
  end

  defp read_all(_conn, buf, _max), do: buf
end
