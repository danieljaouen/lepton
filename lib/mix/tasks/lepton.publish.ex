defmodule Mix.Tasks.Lepton.Publish do
  @shortdoc "Build the ISO and publish it (ISO repo, site checksum/size, submodule)"
  @moduledoc """
  Publishes a new Lepton ISO in one step:

    1. builds `out/lepton.iso` (`mix lepton.iso`; builds are reproducible)
    2. copies it into the ISO repository and regenerates `SHA256SUMS` and
       `README.md` (checksum, size, source revision, versions)
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
  (default `site`), `--allow-dirty` (publish from uncommitted changes).
  """
  use Mix.Task

  @iso "out/lepton.iso"
  @download "https://github.com/danieljaouen/lepton.iso/raw/main/lepton.iso"
  @trailer "\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"

  @impl true
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [build: :boolean, dry_run: :boolean, push: :boolean, iso_repo: :string, site: :string, allow_dirty: :boolean]
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

    if published == sha do
      info("the published ISO already has this checksum - nothing to do")
    else
      info("published checksum: #{published || "(none)"} -> updating")
      publish_iso(iso_repo, sha, bytes, mib, rev, dry, push)
      site_changed = update_site(site, sha, mib, rev, dry, push)
      if site_changed and not dry, do: update_submodule(site, rev, push)
      info(if dry, do: "dry run complete - nothing was written", else: "published")
    end
  end

  # -- steps ------------------------------------------------------------------------

  defp publish_iso(repo, sha, bytes, mib, rev, dry, push) do
    if dry do
      info("would copy #{@iso} to #{repo} and regenerate SHA256SUMS + README.md")
    else
      File.cp!(@iso, Path.join(repo, "lepton.iso"))
      File.write!(Path.join(repo, "SHA256SUMS"), "#{sha}  lepton.iso\n")
      File.write!(Path.join(repo, "README.md"), iso_readme(sha, bytes, mib, rev))
      commit_and_push(repo, ["lepton.iso", "SHA256SUMS", "README.md"], "Lepton OS ISO built from danieljaouen/lepton@#{rev}", push)
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

  defp iso_readme(sha, _bytes, mib, rev) do
    {kernel, otp, elixir} = versions()

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

    This repository is updated by `mix lepton.publish` in the source repository.

    ## Download

        curl -LO #{@download}
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
