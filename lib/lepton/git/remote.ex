defmodule Lepton.Git.Remote do
  @moduledoc """
  The git "smart HTTP" protocol (v0) over HTTPS: clone, fetch, pull and
  push, e.g. against GitHub.

  Authentication for pushes uses a GitHub token, looked up from `GH_TOKEN`
  / `GITHUB_TOKEN` or from `gh auth login` (`~/.config/gh/hosts.yml`, the
  same file GitHub's own `gh` uses).
  """

  alias Lepton.Git
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

    case :httpc.request(method, request, [ssl: ssl_opts(opts), timeout: 120_000, autoredirect: true], body_format: :binary) do
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
      [verify: :verify_peer, cacerts: cacerts(), depth: 10, customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]
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

  def token do
    System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") || Lepton.GH.stored_token()
  end

  defp http_opts(repo) do
    insecure = Config.get(Config.load(repo), "http", "sslverify") in ["false", "0", "no"]
    [insecure: insecure]
  end

  # -- discovery -------------------------------------------------------------------------------

  def ls_remote(url, service, opts \\ []) do
    with {:ok, body} <- http(:get, "#{base(url)}/info/refs?service=#{service}", nil, nil, opts) do
      pkts = parse_pkts(body)
      # Skip "# service=..." and the flush after it.
      lines = pkts |> Enum.drop_while(&(&1 != :flush)) |> Enum.drop(1) |> Enum.reject(&(&1 == :flush))

      {refs, caps} =
        Enum.reduce(lines, {[], ""}, fn line, {refs, caps} ->
          line = String.trim_trailing(line, "\n")

          {line, caps} =
            case :binary.split(line, <<0>>) do
              [l, c] -> {l, c}
              [l] -> {l, caps}
            end

          case String.split(line, " ", parts: 2) do
            [sha, ref] -> {[{ref, sha} | refs], caps}
            _ -> {refs, caps}
          end
        end)

      {:ok, Enum.reverse(refs), caps}
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

  defp upload_pack(url, wants, haves, opts) do
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

    with {:ok, resp} <- http(:post, "#{base(url)}/git-upload-pack", body, "application/x-git-upload-pack-request", opts) do
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

    with {:ok, refs, caps} <- ls_remote(url, "git-upload-pack", opts) do
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
        with {:ok, pack} <- upload_pack(url, Enum.map(heads ++ tags, &elem(&1, 1)), [], opts) do
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
  catch
    {:error, msg} -> {:error, msg}
  end

  def fetch(repo, remote \\ "origin") do
    url = Git.remote_url(repo, remote) || throw({:error, "'#{remote}' does not appear to be a git repository"})
    opts = http_opts(repo)

    with {:ok, refs, _caps} <- ls_remote(url, "git-upload-pack", opts) do
      heads = for {"refs/heads/" <> b, sha} <- refs, do: {b, sha}
      wants = for {_, sha} <- heads, not Object.exists?(repo, sha), do: sha

      n =
        if wants == [] do
          0
        else
          haves = (Git.branches(repo) |> Enum.map(&Git.resolve_ref(repo, "refs/heads/" <> &1))) ++ (Git.remote_branches(repo) |> Enum.map(&Git.resolve_ref(repo, "refs/remotes/" <> &1)))

          case upload_pack(url, wants, Enum.uniq(Enum.reject(haves, &is_nil/1)), opts) do
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
  catch
    {:error, msg} -> {:error, msg}
  end

  def pull(repo, remote, branch) do
    with {:ok, fetched} <- fetch(repo, remote) do
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
    url = Git.remote_url(repo, remote) || throw({:error, "'#{remote}' does not appear to be a git repository"})
    local = Git.resolve_ref(repo, "refs/heads/" <> branch) || throw({:error, "src refspec #{branch} does not match any"})
    token = opts[:token] || token()
    hopts = http_opts(repo) ++ [token: token]

    with {:ok, refs, _caps} <- ls_remote(url, "git-receive-pack", hopts) do
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

          with {:ok, resp} <- http(:post, "#{base(url)}/git-receive-pack", body, "application/x-git-receive-pack-request", hopts) do
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
  catch
    {:error, msg} -> {:error, msg}
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
          children = for {_mode, _name, s} <- Object.parse_tree(content), do: s
          reachable(repo, children ++ rest, acc)

        _ ->
          reachable(repo, rest, acc)
      end
    end
  end
end
