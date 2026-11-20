defmodule Lepton.GH do
  @moduledoc """
  `gh` - a GitHub CLI for Lepton, talking to the GitHub REST API.

      gh auth login [--with-token]     store a token (~/.config/gh/hosts.yml)
      gh auth status | token | logout
      gh repo view [OWNER/REPO] | list [OWNER] | clone OWNER/REPO [DIR] | create NAME [--private]
      gh ssh-key list | add [KEY.pub] [-t TITLE]   your SSH keys on GitHub
      gh config get|set git_protocol [https|ssh]   how gh repo clone clones
      gh issue list | view N | create -t TITLE [-b BODY]
      gh pr list | view N
      gh browse                        print the repository's GitHub URL
      gh api PATH [-X METHOD] [-f key=value]...

  Inside a repository, OWNER/REPO defaults to the `origin` remote.
  """

  alias Lepton.{Ctx, IO}

  @api "https://api.github.com"

  def hosts_path(home), do: Path.join(home, ".config/gh/hosts.yml")

  def stored_token(home \\ nil) do
    home = home || System.get_env("HOME") || "/root"

    case File.read(hosts_path(home)) do
      {:ok, text} ->
        case Regex.run(~r/oauth_token:\s*(\S+)/, text) do
          [_, t] -> t
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp token(ctx), do: Ctx.get_env(ctx, "GH_TOKEN") || Ctx.get_env(ctx, "GITHUB_TOKEN") || stored_token(Ctx.home(ctx))

  # -- HTTP ----------------------------------------------------------------------------

  def request(ctx, method, path, body \\ nil) do
    :inets.start()
    :ssl.start()
    url = if String.starts_with?(path, "http"), do: path, else: @api <> "/" <> String.trim_leading(path, "/")

    headers =
      [{~c"user-agent", ~c"lepton-gh/0.1"}, {~c"accept", ~c"application/vnd.github+json"}, {~c"x-github-api-version", ~c"2022-11-28"}] ++
        case token(ctx) do
          nil -> []
          t -> [{~c"authorization", String.to_charlist("Bearer " <> t)}]
        end

    req =
      if body,
        do: {String.to_charlist(url), headers, ~c"application/json", JSON.encode!(body)},
        else: {String.to_charlist(url), headers}

    case :httpc.request(method, req, [ssl: Lepton.Git.Remote.ssl_opts([]), timeout: 60_000], [body_format: :binary], Lepton.Proxy.httpc_profile(url, ctx.env)) do
      {:ok, {{_, code, _}, _h, resp}} when code in 200..299 ->
        {:ok, if(resp == "", do: nil, else: JSON.decode!(resp))}

      {:ok, {{_, code, _}, _h, resp}} ->
        message = case JSON.decode(resp) do
          {:ok, %{"message" => m}} -> m
          _ -> resp
        end

        {:error, "HTTP #{code}: #{message}"}

      {:error, reason} ->
        {:error, "network error: #{inspect(reason)}"}
    end
  end

  # -- repository detection --------------------------------------------------------------

  def repo_url(dir) do
    with root when root != nil <- Lepton.Git.root(dir),
         url when url != nil <- Lepton.Git.remote_url(Lepton.Git.Repo.open(root), "origin"),
         {:ok, nwo} <- nwo_from_url(url) do
      {:ok, "https://github.com/" <> nwo}
    else
      _ -> :error
    end
  end

  def nwo_from_url(url) do
    case Regex.run(~r{github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$}, url) do
      [_, owner, repo] -> {:ok, "#{owner}/#{repo}"}
      _ -> :error
    end
  end

  defp current_nwo(ctx) do
    case repo_url(ctx.cwd) do
      {:ok, "https://github.com/" <> nwo} -> nwo
      _ -> nil
    end
  end

  # -- commands ----------------------------------------------------------------------------

  def run(["auth", "login" | rest], ctx) do
    token =
      if "--with-token" in rest do
        ctx.stdin |> IO.read_all() |> String.trim()
      else
        IO.write(ctx.stderr, "Paste a GitHub token (https://github.com/settings/tokens, scopes: repo, read:org): ")
        case IO.read_line(ctx.stdin) do
          :eof -> ""
          line -> String.trim(line)
        end
      end

    if token == "" do
      IO.err(ctx, "gh: no token provided")
      1
    else
      user =
        case request(%{ctx | env: Map.put(ctx.env, "GH_TOKEN", token)}, :get, "/user") do
          {:ok, %{"login" => login}} -> login
          _ -> nil
        end

      path = hosts_path(Ctx.home(ctx))
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "github.com:\n    oauth_token: #{token}\n    user: #{user || ""}\n    git_protocol: #{git_protocol(ctx)}\n")
      File.chmod(path, 0o600)
      IO.puts(ctx, if(user, do: "✓ Logged in to github.com as #{user}", else: "✓ Token stored (could not verify it - offline?)"))
      0
    end
  end

  def run(["auth", "status" | _], ctx) do
    case token(ctx) do
      nil ->
        IO.err(ctx, "You are not logged into any GitHub hosts. Run gh auth login to authenticate.")
        1

      _ ->
        case request(ctx, :get, "/user") do
          {:ok, %{"login" => login}} -> IO.puts(ctx, "github.com\n  ✓ Logged in to github.com as #{login}\n  ✓ Git operations for github.com configured to use #{git_protocol(ctx)} protocol."); 0
          {:error, e} -> IO.err(ctx, "github.com: token present but #{e}"); 1
        end
    end
  end

  def run(["auth", "token" | _], ctx) do
    case token(ctx) do
      nil -> IO.err(ctx, "no oauth token"); 1
      t -> IO.puts(ctx, t); 0
    end
  end

  def run(["auth", "logout" | _], ctx) do
    File.rm(hosts_path(Ctx.home(ctx)))
    IO.puts(ctx, "✓ Logged out of github.com")
    0
  end

  def run(["repo", "view" | rest], ctx) do
    nwo = List.first(rest) || current_nwo(ctx)

    with nwo when nwo != nil <- nwo, {:ok, r} <- request(ctx, :get, "/repos/#{nwo}") do
      IO.puts(ctx, "\e[1m#{r["full_name"]}\e[0m")
      if r["description"], do: IO.puts(ctx, r["description"])
      IO.puts(ctx, "\n#{r["stargazers_count"]} stars · #{r["forks_count"]} forks · #{r["open_issues_count"]} open issues · default branch #{r["default_branch"]}")
      IO.puts(ctx, "#{if r["private"], do: "private", else: "public"} · #{r["language"] || "-"} · #{r["html_url"]}")
      readme(ctx, nwo)
      0
    else
      nil -> IO.err(ctx, "gh: no GitHub repository here; pass OWNER/REPO"); 1
      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  def run(["repo", "list" | rest], ctx) do
    path = case rest do
      [owner | _] -> "/users/#{owner}/repos?per_page=50&sort=updated"
      [] -> "/user/repos?per_page=50&sort=updated"
    end

    case request(ctx, :get, path) do
      {:ok, repos} ->
        for r <- repos do
          IO.puts(ctx, String.pad_trailing(r["full_name"], 40) <> " " <> String.slice(r["description"] || "", 0, 50) <> if(r["private"], do: "  (private)", else: ""))
        end

        0

      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  def run(["repo", "clone", nwo | rest], ctx) do
    nwo = if String.contains?(nwo, "/"), do: nwo, else: "#{gh_user(ctx)}/#{nwo}"
    dest = Ctx.path(ctx, List.first(rest) || Path.basename(nwo))
    IO.puts(ctx, "Cloning into '#{Ctx.tildify(ctx, dest)}'...")

    url = if git_protocol(ctx) == "ssh", do: "git@github.com:#{nwo}.git", else: "https://github.com/#{nwo}.git"

    case Lepton.Git.Remote.clone(url, dest, home: Ctx.home(ctx)) do
      {:ok, msg} -> IO.puts(ctx, msg); 0
      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  def run(["repo", "create", name | rest], ctx) do
    private = "--private" in rest

    case request(ctx, :post, "/user/repos", %{name: name, private: private}) do
      {:ok, r} -> IO.puts(ctx, "✓ Created repository #{r["full_name"]} on GitHub\n#{r["clone_url"]}"); 0
      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  def run(["issue", "list" | rest], ctx), do: list_items(ctx, rest, "issues")
  def run(["pr", "list" | rest], ctx), do: list_items(ctx, rest, "pulls")
  def run(["issue", "view", n | _], ctx), do: view_item(ctx, "issues", n)
  def run(["pr", "view", n | _], ctx), do: view_item(ctx, "pulls", n)

  def run(["issue", "create" | rest], ctx) do
    {opts, _} = Lepton.Args.getopt(rest, "t:b:")

    with nwo when nwo != nil <- current_nwo(ctx),
         title when title != nil <- opts["t"] || opts["title"],
         {:ok, i} <- request(ctx, :post, "/repos/#{nwo}/issues", %{title: title, body: opts["b"] || opts["body"] || ""}) do
      IO.puts(ctx, i["html_url"])
      0
    else
      nil -> IO.err(ctx, "usage: gh issue create -t TITLE [-b BODY] (inside a GitHub repository)"); 1
      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  def run(["ssh-key", "list" | _], ctx) do
    case request(ctx, :get, "/user/keys") do
      {:ok, []} ->
        IO.puts(ctx, "No SSH keys on your GitHub account. Add one with: gh ssh-key add")
        0

      {:ok, keys} ->
        for k <- keys, do: IO.puts(ctx, "#{String.pad_trailing(k["title"] || "", 24)} #{String.slice(k["key"], 0, 40)}...  #{String.slice(k["created_at"] || "", 0, 10)}")
        0

      {:error, e} ->
        ssh_key_error(ctx, e)
    end
  end

  def run(["ssh-key", "add" | rest], ctx) do
    {opts, files} = Lepton.Args.getopt(rest, "t:")
    file = Ctx.path(ctx, List.first(files) || "~/.ssh/id_ed25519.pub")

    with {:ok, text} <- File.read(file),
         key = text |> String.trim() |> String.split() |> Enum.take(2) |> Enum.join(" "),
         true <- String.starts_with?(key, ["ssh-", "ecdsa-"]) || {:error, "#{Ctx.tildify(ctx, file)} is not a public key"},
         title = opts["t"] || opts["title"] || title_from(text),
         {:ok, _} <- request(ctx, :post, "/user/keys", %{title: title, key: key}) do
      IO.puts(ctx, "✓ Public key added to your account (#{title})")
      0
    else
      {:error, :enoent} -> IO.err(ctx, "gh: #{Ctx.tildify(ctx, file)} not found; create a key with ssh-keygen"); 1
      {:error, e} when is_binary(e) -> ssh_key_error(ctx, e)
      {:error, e} -> IO.err(ctx, "gh: #{inspect(e)}"); 1
    end
  end

  def run(["config", "get", "git_protocol" | _], ctx), do: (IO.puts(ctx, git_protocol(ctx)); 0)

  def run(["config", "set", "git_protocol", proto | _], ctx) when proto in ["https", "ssh"] do
    home = Ctx.home(ctx)
    config = Path.join(home, ".config/gh/config.yml")
    File.mkdir_p!(Path.dirname(config))
    set_yaml(config, ~r/^git_protocol:.*$/m, "git_protocol: #{proto}")
    if File.exists?(hosts_path(home)), do: set_yaml(hosts_path(home), ~r/^(\s+)git_protocol:.*$/m, "\\1git_protocol: #{proto}", false)
    0
  end

  def run(["config" | _], ctx) do
    IO.err(ctx, "usage: gh config get git_protocol | gh config set git_protocol https|ssh")
    1
  end

  def run(["browse" | _], ctx) do
    case repo_url(ctx.cwd) do
      {:ok, url} -> IO.puts(ctx, url); 0
      :error -> IO.err(ctx, "gh: not a GitHub repository"); 1
    end
  end

  def run(["api", path | rest], ctx) do
    {opts, fields} = parse_api_args(rest, %{}, [])
    method = opts |> Map.get("X", if(fields == [], do: "GET", else: "POST")) |> String.downcase() |> String.to_atom()
    body = if fields == [], do: nil, else: Map.new(fields)
    nwo = current_nwo(ctx)
    path = if nwo, do: String.replace(path, "{owner}/{repo}", nwo), else: path

    case request(ctx, method, path, body) do
      {:ok, data} -> IO.puts(ctx, JSON.encode!(data) |> pretty()); 0
      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  def run(_, ctx) do
    IO.puts(ctx, @moduledoc |> String.split("\n") |> Enum.drop(2) |> Enum.join("\n") |> String.trim_trailing())
    0
  end

  defp parse_api_args(["-X", m | rest], opts, f), do: parse_api_args(rest, Map.put(opts, "X", m), f)
  defp parse_api_args([flag, kv | rest], opts, f) when flag in ["-f", "-F", "--field", "--raw-field"] do
    [k, v] = String.split(kv, "=", parts: 2)
    parse_api_args(rest, opts, f ++ [{k, v}])
  end
  defp parse_api_args([_ | rest], opts, f), do: parse_api_args(rest, opts, f)
  defp parse_api_args([], opts, f), do: {opts, f}

  defp list_items(ctx, rest, kind) do
    nwo = List.first(rest) || current_nwo(ctx)

    with nwo when nwo != nil <- nwo, {:ok, items} <- request(ctx, :get, "/repos/#{nwo}/#{kind}?state=open&per_page=30") do
      items = if kind == "issues", do: Enum.reject(items, &Map.has_key?(&1, "pull_request")), else: items
      if items == [], do: IO.puts(ctx, "No open #{if kind == "pulls", do: "pull requests", else: "issues"} in #{nwo}")

      for i <- items do
        IO.puts(ctx, "##{String.pad_trailing(to_string(i["number"]), 6)} #{String.pad_trailing(String.slice(i["title"], 0, 60), 60)} #{i["user"]["login"]}")
      end

      0
    else
      nil -> IO.err(ctx, "gh: no GitHub repository here; pass OWNER/REPO"); 1
      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  defp view_item(ctx, kind, n) do
    with nwo when nwo != nil <- current_nwo(ctx), {:ok, i} <- request(ctx, :get, "/repos/#{nwo}/#{kind}/#{n}") do
      IO.puts(ctx, "\e[1m#{i["title"]}\e[0m ##{i["number"]}\n#{i["state"]} · #{i["user"]["login"]} · #{i["comments"]} comments\n")
      IO.puts(ctx, i["body"] || "(no description)")
      IO.puts(ctx, "\nView on GitHub: #{i["html_url"]}")
      0
    else
      nil -> IO.err(ctx, "gh: not inside a GitHub repository"); 1
      {:error, e} -> IO.err(ctx, "gh: #{e}"); 1
    end
  end

  defp readme(ctx, nwo) do
    case request(ctx, :get, "/repos/#{nwo}/readme") do
      {:ok, %{"content" => b64}} ->
        text = b64 |> String.replace("\n", "") |> Base.decode64!()
        IO.puts(ctx, "\n" <> (text |> String.split("\n") |> Enum.take(30) |> Enum.join("\n")))

      _ ->
        :ok
    end
  end

  @doc "`https` or `ssh`: hosts.yml's setting for github.com, else config.yml's."
  def git_protocol(ctx) do
    home = Ctx.home(ctx)

    Enum.find_value([hosts_path(home), Path.join(home, ".config/gh/config.yml")], "https", fn path ->
      case File.read(path) do
        {:ok, text} ->
          case Regex.run(~r/^\s*git_protocol:\s*(\S+)/m, text) do
            [_, p] -> p
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  # Replace the line matching `re`, or append `line` when `add?`.
  defp set_yaml(path, re, line, add? \\ true) do
    text = case File.read(path) do
      {:ok, t} -> t
      _ -> ""
    end

    cond do
      Regex.match?(re, text) -> File.write!(path, Regex.replace(re, text, line, global: false))
      add? -> File.write!(path, String.trim_trailing(text) <> if(text == "", do: "", else: "\n") <> line <> "\n")
      true -> :ok
    end
  end

  defp title_from(pub_text) do
    case String.split(String.trim(pub_text)) do
      [_, _, comment | _] -> comment
      _ -> "lepton"
    end
  end

  defp ssh_key_error(ctx, e) do
    hint =
      if e =~ ~r/HTTP (403|404)/,
        do: "\nThe token needs the admin:public_key scope: create one at https://github.com/settings/tokens and run gh auth login,\nor add the key at https://github.com/settings/ssh/new",
        else: ""

    IO.err(ctx, "gh: #{e}#{hint}")
    1
  end

  defp gh_user(ctx) do
    case request(ctx, :get, "/user") do
      {:ok, %{"login" => l}} -> l
      _ -> ""
    end
  end

  # Minimal JSON pretty printer for `gh api`.
  defp pretty(json) do
    {out, _, _} =
      json
      |> String.graphemes()
      |> Enum.reduce({"", 0, false}, fn ch, {acc, depth, in_str} ->
        cond do
          in_str and ch == "\"" and not String.ends_with?(acc, "\\") -> {acc <> ch, depth, false}
          in_str -> {acc <> ch, depth, true}
          ch == "\"" -> {acc <> ch, depth, true}
          ch in ["{", "["] -> {acc <> ch <> "\n" <> String.duplicate("  ", depth + 1), depth + 1, false}
          ch in ["}", "]"] -> {acc <> "\n" <> String.duplicate("  ", depth - 1) <> ch, depth - 1, false}
          ch == "," -> {acc <> ",\n" <> String.duplicate("  ", depth), depth, false}
          ch == ":" -> {acc <> ": ", depth, false}
          true -> {acc <> ch, depth, false}
        end
      end)

    out
  end
end
