defmodule Lepton.Git.Remote do
  @moduledoc """
  The git protocol (v0) over HTTPS ("smart HTTP") and SSH: clone, fetch,
  pull and push, e.g. against GitHub.

  HTTPS pushes to GitHub authenticate with a GitHub token, looked up from
  `GH_TOKEN` / `GITHUB_TOKEN` or from `gh auth login`
  (`~/.config/gh/hosts.yml` in the user's home, `opts[:home]`: the same
  file GitHub's own `gh` uses); clones and fetches send it when GitHub
  asks (a private repository). It goes to github.com only. SSH remotes (`git@github.com:OWNER/REPO`,
  `ssh://[user@]host[:port]/path`) use the user's SSH key (see `Lepton.SSH`).
  `url.<base>.insteadOf` / `pushInsteadOf` rewrite remote URLs, as in git.
  """

  alias Lepton.{Git, SSH}
  alias Lepton.Git.{Config, Object, Pack, Repo}

  @agent "agent=lepton-git/0.1"

  # -- pkt-line ------------------------------------------------------------------------

  def pkt(data), do: (byte_size(data) + 4) |> Integer.to_string(16) |> String.pad_leading(4, "0") |> Kernel.<>(data)
  def flush, do: "0000"

  def parse_pkts(<<>>), do: []
  def parse_pkts(<<"0000", rest::binary>>), do: [:flush | parse_pkts(rest)]
  def parse_pkts(<<"0001", rest::binary>>), do: [:delim | parse_pkts(rest)]

  def parse_pkts(<<len::binary-size(4), rest::binary>>) do
    n = String.to_integer(len, 16) - 4
    <<data::binary-size(^n), rest::binary>> = rest
    [data | parse_pkts(rest)]
  end

  # -- HTTP --------------------------------------------------------------------------------

  defp http(method, url, body, content_type, opts) do
    :inets.start()
    :ssl.start()
    headers = [{~c"user-agent", ~c"git/2.45.0 (lepton)"}, {~c"accept", ~c"*/*"}] ++ auth_header(opts[:token])

    request =
      case method do
        :get -> {String.to_charlist(url), headers}
        :post -> {String.to_charlist(url), headers, String.to_charlist(content_type), body}
      end

    case :httpc.request(method, request, [ssl: ssl_opts(opts), timeout: 120_000, autoredirect: true], [body_format: :binary], Lepton.Proxy.httpc_profile(url, opts[:env] || %{})) do
      {:ok, {{_, 200, _}, _h, resp}} -> {:ok, resp}
      {:ok, {{_, 401, _}, _, _}} -> {:error, "authentication required (run `gh auth login` or set GH_TOKEN)"}
      {:ok, {{_, 403, _}, _, body}} -> {:error, "permission denied: #{String.slice(to_string(body), 0, 200)}"}
      {:ok, {{_, 404, _}, _, _}} -> {:error, "repository not found"}
      {:ok, {{_, code, _}, _, body}} -> {:error, "HTTP #{code}: #{String.slice(to_string(body), 0, 200)}"}
      {:error, reason} -> {:error, "network error: #{inspect(reason)}"}
    end
  end

  def ssl_opts(opts) do
    if opts[:insecure] do
      [verify: :verify_none]
    else
      # (and Lepton's local CA, for development certificates: Lepton.Certs)
      [verify: :verify_peer, cacerts: cacerts() ++ Lepton.Certs.extra_cacerts(), depth: 10, customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]
    end
  end

  defp cacerts do
    :public_key.cacerts_get()
  rescue
    _ ->
      case File.read("/etc/ssl/certs/ca-certificates.crt") do
        {:ok, pem} -> for {:Certificate, der, _} <- :public_key.pem_decode(pem), do: der
        _ -> []
      end
  end

  defp auth_header(nil), do: []
  defp auth_header(token), do: [{~c"authorization", String.to_charlist("Basic " <> Base.encode64("x-access-token:" <> token))}]

  @doc "The user's GitHub token: `GH_TOKEN` / `GITHUB_TOKEN` (`opts[:env]`, then the system's), or `gh auth login`'s in `opts[:home]`."
  def token(opts \\ []) do
    env = opts[:env] || %{}

    env["GH_TOKEN"] || env["GITHUB_TOKEN"] || System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") ||
      Lepton.GH.stored_token(opts[:home])
  end

  # The token for an HTTPS URL on GitHub (never sent anywhere else).
  defp github_token(url, opts) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when host in ["github.com", "www.github.com"] -> token(opts)
      _ -> nil
    end
  end

  defp http_opts(cfg) do
    [insecure: Config.get(cfg, "http", "sslverify") in ["false", "0", "no"]]
  end

  # The remote's URL for fetching or pushing, after insteadOf rewriting.
  defp remote_url!(repo, cfg, remote, kind) do
    url = Git.remote_url(repo, remote) || throw({:error, "'#{remote}' does not appear to be a git repository"})
    rewrite_url(url, cfg, kind)
  end

  # -- transports --------------------------------------------------------------------------
  #
  # open/3 reads the remote's ref advertisement for `service`
  # (git-upload-pack or git-receive-pack) and returns a connection;
  # exchange/3 sends one request on it and returns the response; close/1
  # ends it. Over HTTPS each step is a separate request; over SSH they share
  # one channel running the service on the server.

  def ls_remote(url, service, opts \\ []) do
    with {:ok, refs, caps, conn} <- open(url, service, opts) do
      close(conn)
      {:ok, refs, caps}
    end
  end

  defp open(url, service, opts) do
    case ssh_url(url) do
      nil ->
        case http(:get, "#{base(url)}/info/refs?service=#{service}", nil, nil, opts) do
          {:ok, body} ->
            # Skip "# service=..." and the flush after it.
            {refs, caps} = body |> parse_pkts() |> Enum.drop_while(&(&1 != :flush)) |> Enum.drop(1) |> advertisement()
            {:ok, refs, caps, {:http, url, opts}}

          # A private repository on GitHub: again, with the user's token.
          {:error, "authentication required" <> _} = err ->
            case !opts[:token] && github_token(url, opts) do
              t when is_binary(t) -> open(url, service, Keyword.put(opts, :token, t))
              _ -> err
            end

          err ->
            err
        end

      {target, port, path} ->
        with {:ok, conn, _} <- SSH.connect(target, port: port, home: opts[:home]),
             {:ok, ch} <- ssh_exec(conn, "#{service} #{shell_quote(path)}") do
          case SSH.recv_until(conn, ch, &pkts_complete?/1) do
            {:ok, data} ->
              {refs, caps} = data |> parse_pkts() |> advertisement()
              {:ok, refs, caps, {:ssh, conn, ch}}

            {:closed, _, err, _} ->
              SSH.close(conn)
              {:error, ssh_error(err)}
          end
        end
    end
  end

  defp ssh_exec(conn, command) do
    case SSH.exec(conn, command) do
      {:ok, ch} -> {:ok, ch}
      err -> SSH.close(conn); err
    end
  end

  defp exchange({:http, url, opts}, service, body),
    do: http(:post, "#{base(url)}/#{service}", body, "application/x-#{service}-request", opts)

  defp exchange({:ssh, conn, ch}, _service, body) do
    with :ok <- :ssh_connection.send(conn, ch, body, 300_000),
         :ok <- :ssh_connection.send_eof(conn, ch) do
      case SSH.recv_all(conn, ch) do
        {"", err, _} -> {:error, ssh_error(err)}
        {out, _err, _} -> {:ok, out}
      end
    else
      _ -> {:error, ssh_error("")}
    end
  end

  defp close({:http, _, _}), do: :ok

  defp close({:ssh, conn, ch}) do
    # A flush tells the service there is nothing to do, if it still waits.
    _ = :ssh_connection.send(conn, ch, flush(), 2000)
    SSH.close(conn)
  catch
    _, _ -> :ok
  end

  # Refs and capabilities from an advertisement's pkt-lines.
  defp advertisement(pkts) do
    lines = Enum.reject(pkts, &(&1 in [:flush, :delim]))

    {refs, caps} =
      Enum.reduce(lines, {[], ""}, fn line, {refs, caps} ->
        line = String.trim_trailing(line, "\n")

        {line, caps} =
          case :binary.split(line, <<0>>) do
            [l, c] -> {l, c}
            [l] -> {l, caps}
          end

        case String.split(line, " ", parts: 2) do
          # An empty repository advertises "0{40} capabilities^{}".
          [_, "capabilities^{}"] -> {refs, caps}
          [sha, ref] -> {[{ref, sha} | refs], caps}
          _ -> {refs, caps}
        end
      end)

    {Enum.reverse(refs), caps}
  end

  # Has `data` got whole pkt-lines up to a flush?
  defp pkts_complete?(<<"0000", _::binary>>), do: true

  defp pkts_complete?(<<len::binary-size(4), rest::binary>>) do
    case Integer.parse(len, 16) do
      {n, ""} when n >= 4 and byte_size(rest) >= n - 4 -> pkts_complete?(binary_part(rest, n - 4, byte_size(rest) - n + 4))
      _ -> false
    end
  end

  defp pkts_complete?(_), do: false

  # GitHub and git-shell print "ERROR: Repository not found." and the like.
  defp ssh_error(err) do
    case String.trim(err) do
      "" -> "the remote end hung up unexpectedly"
      msg -> msg |> String.replace(~r/^(ERROR|fatal):\s*/m, "") |> String.trim()
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"

  @doc """
  `{target, port, path}` for an SSH URL (`ssh://[user@]host[:port]/path` or
  scp-like `[user@]host:path`), or nil.
  """
  def ssh_url(url) do
    cond do
      m = Regex.run(~r{^(?:ssh|git\+ssh|ssh\+git)://(?:([^@/]+)@)?(\[[^\]]+\]|[^:/]+)(?::(\d+))?(/.*)$}, url) ->
        [_, user, host, port, path] = m
        host = String.trim(host, "[") |> String.trim("]")
        # ssh://host/~user/repo is relative to a home directory.
        path = if String.starts_with?(path, "/~"), do: String.trim_leading(path, "/"), else: path
        {target(user, host), if(port == "", do: nil, else: String.to_integer(port)), path}

      String.contains?(url, "://") ->
        nil

      m = Regex.run(~r{^(?:([^@/:]+)@)?([^@/:]+):(.+)$}, url) ->
        [_, user, host, path] = m
        {target(user, host), nil, path}

      true ->
        nil
    end
  end

  defp target("", host), do: host
  defp target(user, host), do: "#{user}@#{host}"

  @doc "Apply `url.<base>.insteadOf` (and `pushInsteadOf` for pushes) from `cfg`."
  def rewrite_url(url, cfg, kind \\ :fetch) do
    keys = if kind == :push, do: ["pushinsteadof", "insteadof"], else: ["insteadof"]

    candidates =
      for {"url \"" <> base, kvs} <- cfg, key <- keys, prefix = kvs[key], prefix != nil, String.starts_with?(url, prefix),
          do: {key, prefix, String.trim_trailing(base, "\"")}

    # pushInsteadOf before insteadOf; the longest match wins.
    case Enum.sort_by(candidates, fn {key, prefix, _} -> {key == "insteadof", -byte_size(prefix)} end) do
      [{_, prefix, base} | _] -> base <> binary_part(url, byte_size(prefix), byte_size(url) - byte_size(prefix))
      [] -> url
    end
  end

  defp base(url) do
    url = String.trim_trailing(url, "/")
    if String.ends_with?(url, ".git"), do: url, else: url <> ".git"
  end

  defp default_branch(refs, caps) do
    case Regex.run(~r/symref=HEAD:refs\/heads\/(\S+)/, caps) do
      [_, b] -> b
      nil ->
        head = List.keyfind(refs, "HEAD", 0)
        case head && Enum.find(refs, fn {r, s} -> String.starts_with?(r, "refs/heads/") and s == elem(head, 1) end) do
          {"refs/heads/" <> b, _} -> b
          _ -> "main"
        end
    end
  end

  # -- fetch / clone ------------------------------------------------------------------------------

  defp upload_pack(conn, wants, haves) do
    caps = "multi_ack_detailed side-band-64k ofs-delta no-progress #{@agent}"
    [first | rest] = Enum.uniq(wants)

    body =
      IO.iodata_to_binary([
        pkt("want #{first} #{caps}\n"),
        Enum.map(rest, &pkt("want #{&1}\n")),
        flush(),
        Enum.map(haves, &pkt("have #{&1}\n")),
        pkt("done\n")
      ])

    with {:ok, resp} <- exchange(conn, "git-upload-pack", body) do
      demux(resp)
    end
  end

  # Separate NAK/ACK lines from side-band data (1 = pack, 2 = progress, 3 = error).
  defp demux(resp), do: demux(resp, [])

  defp demux(<<>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp demux(<<"0000", rest::binary>>, acc), do: demux(rest, acc)

  defp demux(<<len::binary-size(4), rest::binary>> = all, acc) do
    case Integer.parse(len, 16) do
      {n, ""} when n >= 4 and byte_size(rest) >= n - 4 ->
        data = binary_part(rest, 0, n - 4)
        rest = binary_part(rest, n - 4, byte_size(rest) - n + 4)

        case data do
          <<1, pack::binary>> -> demux(rest, [pack | acc])
          <<2, _progress::binary>> -> demux(rest, acc)
          <<3, err::binary>> -> {:error, "remote error: " <> err}
          _ -> demux(rest, acc)
        end

      _ ->
        # Not side-band framed: the rest is raw pack data.
        case :binary.match(all, "PACK") do
          {pos, _} -> {:ok, IO.iodata_to_binary(Enum.reverse([binary_part(all, pos, byte_size(all) - pos) | acc]))}
          :nomatch -> {:error, "unexpected response from server"}
        end
    end
  end

  defp store_pack(repo, pack) do
    objects = Pack.decode(pack, fn sha -> case Object.read(repo, sha) do
      {:ok, obj} -> obj
      _ -> nil
    end end)

    for {_sha, type, content} <- objects, do: Object.write(repo, type, content)
    length(objects)
  end

  def clone(url, dest, opts \\ []) do
    if File.exists?(dest) and File.ls!(dest) != [], do: throw({:error, "destination path '#{dest}' already exists and is not an empty directory"})

    cfg = Config.global(opts[:home])
    opts = http_opts(cfg) ++ opts

    with {:ok, refs, caps, conn} <- open(rewrite_url(url, cfg), "git-upload-pack", opts) do
      try do
        clone_from(conn, url, dest, refs, caps)
      after
        close(conn)
      end
    end
  catch
    {:error, msg} -> {:error, msg}
  end

  defp clone_from(conn, url, dest, refs, caps) do
    File.mkdir_p!(dest)
    branch = default_branch(refs, caps)
    repo = Repo.init(dest, branch)
    Config.set(repo, "remote \"origin\"", "url", url)
    Config.set(repo, "remote \"origin\"", "fetch", "+refs/heads/*:refs/remotes/origin/*")

    heads = for {"refs/heads/" <> b, sha} <- refs, do: {b, sha}
    tags = for {"refs/tags/" <> t, sha} <- refs, not String.ends_with?(t, "^{}"), do: {t, sha}

    if heads == [] do
      {:ok, "warning: You appear to have cloned an empty repository."}
    else
      with {:ok, pack} <- upload_pack(conn, Enum.map(heads ++ tags, &elem(&1, 1)), []) do
        n = store_pack(repo, pack)
        for {b, sha} <- heads, do: Git.update_ref(repo, "refs/remotes/origin/" <> b, sha)
        for {t, sha} <- tags, do: Git.update_ref(repo, "refs/tags/" <> t, sha)
        File.write!(Path.join(repo.git_dir, "refs/remotes/origin/HEAD"), "ref: refs/remotes/origin/#{branch}\n")

        case List.keyfind(heads, branch, 0) do
          {_, sha} ->
            Git.update_ref(repo, "refs/heads/" <> branch, sha)
            Config.set(repo, "branch \"#{branch}\"", "remote", "origin")
            Config.set(repo, "branch \"#{branch}\"", "merge", "refs/heads/" <> branch)
            Git.write_worktree(repo, %{}, Git.flatten_tree(repo, Git.read_commit(repo, sha).tree))

          nil ->
            :ok
        end

        {:ok, "Received #{n} objects; checked out '#{branch}'."}
      end
    end
  end

  def fetch(repo, remote \\ "origin", opts \\ []) do
    cfg = Config.load(repo)
    url = remote_url!(repo, cfg, remote, :fetch)

    with {:ok, refs, _caps, conn} <- open(url, "git-upload-pack", http_opts(cfg) ++ opts) do
      try do
        fetch_from(conn, repo, remote, refs)
      after
        close(conn)
      end
    end
  catch
    {:error, msg} -> {:error, msg}
  end

  defp fetch_from(conn, repo, remote, refs) do
    heads = for {"refs/heads/" <> b, sha} <- refs, do: {b, sha}
    wants = for {_, sha} <- heads, not Object.exists?(repo, sha), do: sha

    n =
      if wants == [] do
        0
      else
        haves = (Git.branches(repo) |> Enum.map(&Git.resolve_ref(repo, "refs/heads/" <> &1))) ++ (Git.remote_branches(repo) |> Enum.map(&Git.resolve_ref(repo, "refs/remotes/" <> &1)))

        case upload_pack(conn, wants, Enum.uniq(Enum.reject(haves, &is_nil/1))) do
          {:ok, pack} -> store_pack(repo, pack)
          {:error, e} -> throw({:error, e})
        end
      end

    updated =
      for {b, sha} <- heads, Git.resolve_ref(repo, "refs/remotes/#{remote}/" <> b) != sha do
        Git.update_ref(repo, "refs/remotes/#{remote}/" <> b, sha)
        b
      end

    {:ok, if(updated == [], do: "Already up to date.", else: "Fetched #{n} objects; updated #{Enum.join(updated, ", ")}.")}
  end

  def pull(repo, remote, branch, opts \\ []) do
    with {:ok, fetched} <- fetch(repo, remote, opts) do
      case Git.resolve_ref(repo, "refs/remotes/#{remote}/#{branch}") do
        nil -> {:ok, fetched}
        sha ->
          case Git.fast_forward(repo, sha) do
            {:ok, msg} -> {:ok, fetched <> "\n" <> msg}
            err -> err
          end
      end
    end
  end

  # -- push ------------------------------------------------------------------------------------

  def push(repo, remote, branch, opts \\ []) do
    cfg = Config.load(repo)
    url = remote_url!(repo, cfg, remote, :push)
    local = Git.resolve_ref(repo, "refs/heads/" <> branch) || throw({:error, "src refspec #{branch} does not match any"})
    # The token is for HTTPS only; SSH remotes use the SSH key.
    hopts = http_opts(cfg) ++ Keyword.delete(opts, :token) ++ [token: opts[:token] || github_token(url, opts)]

    with {:ok, refs, _caps, conn} <- open(url, "git-receive-pack", hopts) do
      try do
        push_to(conn, repo, remote, url, branch, local, refs, opts)
      after
        close(conn)
      end
    end
  catch
    {:error, msg} -> {:error, msg}
  end

  defp push_to(conn, repo, remote, url, branch, local, refs, opts) do
    ref = "refs/heads/" <> branch
    remote_sha = case List.keyfind(refs, ref, 0) do
      {_, sha} -> sha
      nil -> String.duplicate("0", 40)
    end

    cond do
      remote_sha == local ->
        {:ok, "Everything up-to-date"}

      remote_sha != String.duplicate("0", 40) && not Object.exists?(repo, remote_sha) && !opts[:force] ->
        {:error, "Updates were rejected because the remote contains work that you do not have locally. Pull first."}

      true ->
        objects = objects_to_send(repo, local, remote_sha)
        pack = Pack.encode(objects)
        cmd = "#{remote_sha} #{local} #{ref}\0report-status side-band-64k #{@agent}\n"
        body = pkt(cmd) <> flush() <> pack

        with {:ok, resp} <- exchange(conn, "git-receive-pack", body) do
          report = report_status(resp)

          cond do
            String.contains?(report, "ok " <> ref) ->
              Git.update_ref(repo, "refs/remotes/#{remote}/" <> branch, local)
              {:ok, "To #{url}\n   #{String.slice(remote_sha, 0, 7)}..#{String.slice(local, 0, 7)}  #{branch} -> #{branch}"}

            true ->
              {:error, "push rejected: " <> String.trim(report)}
          end
        end
    end
  end

  defp report_status(resp) do
    case demux(resp) do
      {:ok, data} when data != "" -> data |> parse_pkts_safe() |> Enum.join()
      _ -> resp |> parse_pkts_safe() |> Enum.join()
    end
  end

  defp parse_pkts_safe(data) do
    parse_pkts(data) |> Enum.reject(&(&1 in [:flush, :delim]))
  rescue
    _ -> [data]
  end

  # Every object reachable from `local` but not from `remote_sha`.
  defp objects_to_send(repo, local, remote_sha) do
    have =
      if Object.exists?(repo, remote_sha),
        do: reachable(repo, [remote_sha], MapSet.new()),
        else: MapSet.new()

    repo |> reachable([local], MapSet.new()) |> MapSet.difference(have) |> Enum.map(&Object.read!(repo, &1))
  end

  defp reachable(_repo, [], acc), do: acc

  defp reachable(repo, [sha | rest], acc) do
    if MapSet.member?(acc, sha) do
      reachable(repo, rest, acc)
    else
      acc = MapSet.put(acc, sha)

      case Object.read!(repo, sha) do
        {:commit, content} ->
          c = Object.parse_commit(content)
          reachable(repo, [c.tree | c.parents] ++ rest, acc)

        {:tree, content} ->
          # (a submodule's commit is another repository's: not sent)
          children = for {mode, _name, s} <- Object.parse_tree(content), not Git.gitlink?(mode), do: s
          reachable(repo, children ++ rest, acc)

        _ ->
          reachable(repo, rest, acc)
      end
    end
  end
end
