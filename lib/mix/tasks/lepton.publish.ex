defmodule Mix.Tasks.Lepton.Publish do
  @shortdoc "Build the ISO and publish it (ISO repo, site checksum/size, submodule)"
  @moduledoc """
  Publishes a new Lepton ISO in one step:

    1. builds `out/lepton.iso` (`mix lepton.iso`; builds are reproducible)
    2. creates a **GitHub Release** on the ISO repository (tag
       `lepton-REV`) with `lepton.iso` and `SHA256SUMS` attached, and
       commits the regenerated `SHA256SUMS` and `README.md` there. The ISO
       itself is never committed: release assets are free, unlimited in
       bandwidth and keep the repository small. The stable download link
       is `…/releases/latest/download/lepton.iso`.
    3. updates the checksum and size shown on the site (`site/index.html`,
       elements marked `data-iso-sha256` / `data-iso-size`)
    4. records the new site commit in this repository's `site` submodule
    5. commits and pushes each repository that changed, rebasing onto any
       remote changes first (e.g. edits made on GitHub)

  If the ISO's checksum is unchanged, nothing is committed.

      mix lepton.publish                 # build and publish
      mix lepton.publish --no-build      # publish the existing out/lepton.iso
      mix lepton.publish --dry-run       # show what would change, touch nothing
      mix lepton.publish --no-push       # commit locally only

  Options: `--iso-repo PATH` (default `../lepton.iso`), `--site PATH`
  (default `site`), `--allow-dirty` (publish from uncommitted changes),
  `--force` (publish even if the checksum is unchanged).

  Creating releases needs a GitHub token: `GH_TOKEN`/`GITHUB_TOKEN`, or a
  logged-in GitHub CLI (`gh auth login`).
  """
  use Mix.Task

  @iso "out/lepton.iso"
  @trailer "\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [build: :boolean, dry_run: :boolean, push: :boolean, iso_repo: :string, site: :string, allow_dirty: :boolean, force: :boolean]
      )

    iso_repo = Path.expand(opts[:iso_repo] || "../lepton.iso")
    site = Path.expand(opts[:site] || "site")
    dry = opts[:dry_run] == true
    push = opts[:push] != false and not dry

    for {name, dir} <- [{"ISO repository", iso_repo}, {"site", site}] do
      unless File.dir?(Path.join(dir, ".git")) or File.regular?(Path.join(dir, ".git")),
        do: Mix.raise("#{name} not found at #{dir} (pass --iso-repo / --site)")

      unless dry or clean?(dir), do: Mix.raise("#{name} at #{dir} has uncommitted changes; commit or stash them first")
    end

    rev = source_revision(opts[:allow_dirty] == true or dry)

    if opts[:build] != false do
      info("building the ISO")
      Mix.Task.run("lepton.iso", [])
    end

    unless File.exists?(@iso), do: Mix.raise("#{@iso} not found; run without --no-build")

    sha = :crypto.hash(:sha256, File.read!(@iso)) |> Base.encode16(case: :lower)
    bytes = File.stat!(@iso).size
    mib = round(bytes / 1_048_576)
    info("ISO #{sha} (#{mib} MiB) from lepton@#{rev}")

    published = published_sha(iso_repo)

    if published == sha and opts[:force] != true do
      info("the published ISO already has this checksum - nothing to do")
    else
      info("published checksum: #{published || "(none)"} -> updating")
      unless dry or push, do: Mix.raise("--no-push cannot be combined with publishing a release")
      publish_iso(iso_repo, sha, bytes, mib, rev, dry)
      site_changed = update_site(site, sha, mib, rev, dry, push)
      if site_changed and not dry, do: update_submodule(site, rev, push)
      info(if dry, do: "dry run complete - nothing was written", else: "published")
    end
  end

  # -- steps ------------------------------------------------------------------------

  defp publish_iso(repo, sha, bytes, mib, rev, dry) do
    {owner, name} = github_repo(repo)
    tag = "lepton-#{rev}"

    if dry do
      info("would create release #{tag} on #{owner}/#{name} with lepton.iso + SHA256SUMS, and regenerate SHA256SUMS + README.md")
    else
      token = token!()
      sums = "#{sha}  lepton.iso\n"
      body = "Lepton OS built from danieljaouen/lepton@#{rev}.\n\nSHA-256: `#{sha}`\n\nSee the README for how to run it."
      release = ensure_release(token, owner, name, tag, "Lepton OS (lepton@#{rev})", body)
      upload_asset(token, release, "lepton.iso", File.read!(@iso))
      upload_asset(token, release, "SHA256SUMS", sums)
      info("released #{release["html_url"]}")

      # The repository keeps only metadata; the ISO lives in releases.
      if git(repo, ["ls-files", "--error-unmatch", "lepton.iso"], allow_fail: true) != :failed do
        git(repo, ["rm", "-q", "--cached", "lepton.iso"])
      end

      File.rm(Path.join(repo, "lepton.iso"))
      File.write!(Path.join(repo, ".gitignore"), "lepton.iso\n")
      File.write!(Path.join(repo, "SHA256SUMS"), sums)
      File.write!(Path.join(repo, "README.md"), iso_readme(sha, bytes, mib, rev, owner, name))
      commit_and_push(repo, [".gitignore", "SHA256SUMS", "README.md"], "Release #{tag}: SHA-256 #{String.slice(sha, 0, 12)}", true)
    end
  end

  # -- GitHub Releases API ------------------------------------------------------------

  defp github_repo(repo) do
    url = git(repo, ["remote", "get-url", "origin"]) |> String.trim()

    case Regex.run(~r{github\.com[:/]([^/]+)/(.+?)(\.git)?$}, url) do
      [_, owner, name | _] -> {owner, name}
      _ -> Mix.raise("#{repo}: origin #{url} is not a GitHub repository")
    end
  end

  def download_url(owner, name), do: "https://github.com/#{owner}/#{name}/releases/latest/download/lepton.iso"

  defp token! do
    from_gh =
      if System.find_executable("gh") do
        case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
          {t, 0} -> String.trim(t)
          _ -> nil
        end
      end

    System.get_env("GH_TOKEN") || System.get_env("GITHUB_TOKEN") || from_gh ||
      Mix.raise("creating a GitHub release needs a token: run `gh auth login` (or set GH_TOKEN)")
  end

  defp ensure_release(token, owner, name, tag, title, body) do
    payload = JSON.encode!(%{tag_name: tag, target_commitish: "main", name: title, body: body, make_latest: "true"})

    case api(token, :post, "https://api.github.com/repos/#{owner}/#{name}/releases", payload, "application/json") do
      {201, release} ->
        release

      {422, _} ->
        # The tag already has a release (re-publishing the same revision).
        {200, release} = api(token, :get, "https://api.github.com/repos/#{owner}/#{name}/releases/tags/#{tag}")
        release

      {status, resp} ->
        Mix.raise("creating release #{tag} failed (HTTP #{status}): #{inspect(resp)}")
    end
  end

  defp upload_asset(token, release, file, data) do
    # Replace an existing asset of the same name.
    for %{"name" => ^file, "url" => url} <- release["assets"] || [] do
      api(token, :delete, url)
    end

    base = release["upload_url"] |> String.replace(~r/\{.*\}$/, "")
    info("uploading #{file} (#{div(byte_size(data), 1_048_576)} MiB)")

    case api(token, :post, base <> "?name=" <> URI.encode_www_form(file), data, "application/octet-stream") do
      {201, _} -> :ok
      {status, resp} -> Mix.raise("uploading #{file} failed (HTTP #{status}): #{inspect(resp)}")
    end
  end

  defp api(token, method, url, body \\ nil, type \\ nil) do
    :inets.start()
    :ssl.start()

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"accept", ~c"application/vnd.github+json"},
      {~c"x-github-api-version", ~c"2022-11-28"},
      {~c"user-agent", ~c"lepton-publish"}
    ]

    request =
      if body,
        do: {String.to_charlist(url), headers, String.to_charlist(type), body},
        else: {String.to_charlist(url), headers}

    ssl = [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]]

    case :httpc.request(method, request, [ssl: ssl, timeout: 900_000], body_format: :binary) do
      {:ok, {{_, status, _}, _, ""}} -> {status, nil}
      {:ok, {{_, status, _}, _, resp}} -> {status, JSON.decode!(resp)}
      {:error, reason} -> Mix.raise("GitHub API #{method} #{url}: #{inspect(reason)}")
    end
  end

  defp update_site(site, sha, mib, rev, dry, push) do
    path = Path.join(site, "index.html")
    html = File.read!(path)

    updated =
      html
      |> replace_marked("data-iso-sha256", sha)
      |> replace_marked("data-iso-size", "#{mib}&nbsp;MiB")

    cond do
      not String.contains?(html, "data-iso-sha256") ->
        Mix.raise("#{path} has no data-iso-sha256 element to update")

      updated == html ->
        info("site already shows this checksum")
        false

      dry ->
        info("would update the checksum and size in #{path}")
        false

      true ->
        File.write!(path, updated)
        commit_and_push(site, ["index.html"], "Update ISO checksum and size (lepton@#{rev})", push)
        true
    end
  end

  defp update_submodule(site, rev, push) do
    root = File.cwd!()
    rel = Path.relative_to(site, root)
    commit_and_push(root, [rel], "Update site submodule for ISO from #{rev}", push)
  end

  # Replace the text content of every element carrying `attr`.
  defp replace_marked(html, attr, value) do
    Regex.replace(~r/(<[^>]*\b#{attr}\b[^>]*>)[^<]*(<\/)/, html, fn _, open, close -> open <> value <> close end)
  end

  # -- git -----------------------------------------------------------------------------

  defp commit_and_push(dir, paths, message, push) do
    git(dir, ["add" | paths])

    if git(dir, ["diff", "--cached", "--quiet"], allow_fail: true) == :failed do
      git(dir, ["commit", "-q", "-m", message <> @trailer])
      info("committed in #{Path.basename(dir)}: #{message}")

      if push do
        # Integrate commits made elsewhere (e.g. on GitHub) instead of forcing.
        git(dir, ["pull", "--rebase", "-q"])
        git(dir, ["push", "-q"])
        info("pushed #{Path.basename(dir)}")
      end
    else
      info("no changes in #{Path.basename(dir)}")
    end
  end

  defp git(dir, args, opts \\ []) do
    case {System.cmd("git", ["-C", dir | args], stderr_to_stdout: true), opts[:allow_fail]} do
      {{out, 0}, _} -> out
      {{_out, _}, true} -> :failed
      {{out, status}, _} -> Mix.raise("git #{Enum.join(args, " ")} failed in #{dir} (#{status}):\n#{out}")
    end
  end

  defp clean?(dir), do: git(dir, ["status", "--porcelain"]) == ""

  defp source_revision(allow_dirty) do
    rev = git(File.cwd!(), ["rev-parse", "--short", "HEAD"]) |> String.trim()
    # Untracked/modified files outside site/ and out/ mean the ISO would not
    # match any commit.
    dirty =
      git(File.cwd!(), ["status", "--porcelain"])
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.match?(&1, ~r/^.. (site|out)(\/|$)/))

    cond do
      dirty == [] -> rev
      allow_dirty -> rev <> "-dirty"
      true -> Mix.raise("this repository has uncommitted changes; commit them first (or pass --allow-dirty)")
    end
  end

  defp published_sha(repo) do
    case File.read(Path.join(repo, "SHA256SUMS")) do
      {:ok, text} -> text |> String.split() |> List.first()
      _ -> nil
    end
  end

  defp versions do
    kernel =
      case File.read("_build/lepton/cache/sources.lock") do
        {:ok, text} ->
          {lock, _} = Code.eval_string(text)
          lock["linux-virt"].version |> String.split("-") |> hd()

        _ ->
          "?"
      end

    otp = LeptonBuild.Sources.otp_version() |> String.replace_prefix("OTP-", "")
    {kernel, otp, System.version()}
  end

  defp iso_readme(sha, _bytes, mib, rev, owner, name) do
    {kernel, otp, elixir} = versions()
    download = download_url(owner, name)

    """
    # Lepton OS - bootable ISO

    Prebuilt `lepton.iso` for [Lepton OS](https://github.com/danieljaouen/lepton),
    a Unix-like operating system for ARM64 (aarch64) whose userland is written in
    Elixir. Website: <https://trylepton.app/>

    | | |
    |---|---|
    | File | `lepton.iso` (#{mib} MiB, UEFI, aarch64, hybrid CD/disk image) |
    | SHA-256 | `#{sha}` |
    | Built from | danieljaouen/lepton @ `#{rev}` (Linux #{kernel}, Erlang/OTP #{otp}, Elixir #{elixir}) |

    The ISO is attached to this repository's
    [Releases](https://github.com/#{owner}/#{name}/releases); every release is
    published by `mix lepton.publish` in the source repository.

    ## Download

        curl -LO #{download}
        shasum -a 256 -c SHA256SUMS

    ## Run it

    **UTM (Apple Silicon):** Create a New Virtual Machine -> Virtualize -> Linux,
    boot from `lepton.iso`, 2 GB+ memory. Add a Serial device for a second
    console. To keep your files, add a VirtIO drive and run `lepton-install`.

    **QEMU:**

        qemu-system-aarch64 -M virt -accel hvf -cpu host -m 2048 \\
          -bios /opt/homebrew/share/qemu/edk2-aarch64-code.fd \\
          -cdrom lepton.iso -nographic

    (Use `-accel tcg -cpu max` on non-Apple hosts.) Inside Lepton, `help` lists
    commands, `lepton-tutorial` gives a tour and `poweroff` shuts down cleanly.

    Note: this image installs Daniel Jaouen's dotfiles into `/root`. Build your
    own with `mix lepton.iso --dotfiles PATH` from the source repository.
    """
  end

  defp info(msg), do: Mix.shell().info([:cyan, "==> ", :reset, msg])
end
