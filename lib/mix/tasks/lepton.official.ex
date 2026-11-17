defmodule Mix.Tasks.Lepton.Official do
  @shortdoc "Manage the signed list of official app updates (lpm upgrade)"
  @moduledoc """
  Maintains `site/official.json` (+ `.sig`), the signed list that lets a
  hex.pm package stand in for a built-in command (see `Lepton.Official`).

      mix lepton.official keygen
      mix lepton.official list
      mix lepton.official add PACKAGE VERSION --replaces grep[,egrep] [--dep NAME@VERSION ...] [--org lepton]
      mix lepton.official remove PACKAGE
      mix lepton.official sign

  `add` refuses a package unless every hex.pm owner is the `lepton`
  organization or one of its members (read live, so you must be logged in
  with `mix hex.user auth`): making something official takes both the org
  and the signing key. It then takes each tarball's SHA-256 and pins it. Every
  non-optional dependency (transitively) must be pinned with `--dep`, since
  lpm refuses unpinned code for official updates. Each change bumps the
  list's `serial` and re-signs it; commit and push the site to publish it.

  The private key lives in the macOS Keychain (service
  `#{"lepton-official-signing-key"}`), never in a repository. `$LEPTON_SIGNING_KEY`
  (a file path) overrides it, e.g. on a machine without a Keychain. The
  public key is `rootfs/etc/lepton/official-key.pub` and is compiled into
  the OS. Losing the private key means generating a new one and shipping a
  new ISO, so keep the Keychain backed up (iCloud Keychain or Time Machine).
  """
  use Mix.Task

  @pub "rootfs/etc/lepton/official-key.pub"
  @manifest "site/official.json"
  @api "https://hex.pm/api"
  @trust "Do not edit by hand: use `mix lepton.official` (the file is signed)."
  @keychain "lepton-official-signing-key"
  @org "lepton"

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [replaces: :string, dep: :keep, description: :string, org: :string])

    case rest do
      ["keygen"] -> keygen()
      ["list"] -> list()
      ["add", package, version] -> add(package, version, opts)
      ["remove", package] -> update(fn apps -> Enum.reject(apps, &(&1["package"] == package)) end, "removed #{package}")
      ["sign"] -> update(& &1, "re-signed")
      _ -> Mix.raise("usage: see `mix help lepton.official`")
    end
  end

  # -- commands ------------------------------------------------------------------------------

  defp keygen do
    if private_key() != nil, do: Mix.raise("a signing key already exists (#{key_source()}) - refusing to overwrite it")
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)

    case System.get_env("LEPTON_SIGNING_KEY") do
      nil ->
        keychain_store!(Base.encode64(priv))
        info("private key: macOS Keychain, service #{@keychain}")

      path ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Base.encode64(priv) <> "\n")
        File.chmod!(path, 0o600)
        info("private key: #{path} (mode 600 - back it up somewhere safe)")
    end

    File.mkdir_p!(Path.dirname(@pub))
    File.write!(@pub, Base.encode64(pub) <> "\n")
    info("public key:  #{@pub} (compiled into the OS; commit it and rebuild the ISO)")
    unless File.exists?(@manifest), do: update(& &1, "created an empty official list")
  end

  defp list do
    %{"serial" => serial, "issued" => issued, "apps" => apps} = read()
    info("official list ##{serial}, issued #{issued}, maintained by the #{org(read())} organization on hex.pm")
    if apps == [], do: info("(no official updates)")

    for a <- apps do
      deps = Enum.map_join(a["deps"] || [], ", ", &"#{&1["package"]} #{&1["version"]}")
      Mix.shell().info("  #{Enum.join(a["replaces"], ", ")} <- #{a["package"]} #{a["version"]}" <> if(deps == "", do: "", else: " (deps: #{deps})"))
    end
  end

  defp add(package, version, opts) do
    replaces = String.split(opts[:replaces] || "", ",", trim: true)
    if replaces == [], do: Mix.raise("--replaces CMD[,CMD] is required")

    builtin = Lepton.Commands.builtins()
    for r <- replaces, not Map.has_key?(builtin, r), do: Mix.raise("#{r} is not a built-in command")
    check_owners!(package, opts[:org] || org(read()))

    deps =
      for d <- Keyword.get_values(opts, :dep) do
        case String.split(d, "@", parts: 2) do
          [n, v] -> {n, v}
          _ -> Mix.raise("--dep must be NAME@VERSION, got #{d}")
        end
      end

    pins = Map.new([{package, version} | deps])
    info("pinning #{package} #{version}" <> if(deps == [], do: "", else: " and #{length(deps)} dependencies"))
    releases = Map.new(pins, fn {n, v} -> {n, release!(n, v)} end)

    # The whole dependency closure must be pinned, at versions satisfying it.
    for {name, rel} <- releases, {dep, spec} <- rel["requirements"] || %{}, !spec["optional"] do
      case pins[dep] do
        nil -> Mix.raise("#{name} depends on #{dep} (#{spec["requirement"]}); pin it with --dep #{dep}@VERSION")
        v -> unless Version.match?(v, spec["requirement"]), do: Mix.raise("#{dep} #{v} does not satisfy #{name}'s requirement #{spec["requirement"]}")
      end
    end

    entry =
      %{"package" => package, "version" => version, "checksum" => releases[package]["checksum"], "replaces" => replaces}
      |> maybe_put("description", opts[:description])
      |> maybe_put("deps", for({n, v} <- deps, do: %{"package" => n, "version" => v, "checksum" => releases[n]["checksum"]}), [])

    # A command can only have one official replacement.
    update(
      fn apps ->
        apps
        |> Enum.reject(&(&1["package"] == package))
        |> Enum.map(&Map.update!(&1, "replaces", fn r -> r -- replaces end))
        |> Enum.reject(&(&1["replaces"] == []))
        |> Kernel.++([entry])
      end,
      "added #{package} #{version} for #{Enum.join(replaces, ", ")}"
    )
  end

  # -- the signed file -----------------------------------------------------------------------------

  defp read do
    case File.read(@manifest) do
      {:ok, json} -> JSON.decode!(json)
      _ -> %{"schema" => 1, "serial" => 0, "issued" => nil, "apps" => []}
    end
  end

  defp org(manifest), do: get_in(manifest, ["maintainers", "hex_organization"]) || @org

  defp update(fun, message) do
    priv = private_key!()
    old = read()
    data = %{old | "serial" => old["serial"] + 1, "issued" => Date.to_iso8601(Date.utc_today()), "apps" => fun.(old["apps"])}
    data = Map.put(data, "maintainers", %{"hex_organization" => org(old)})
    json = encode(data)
    sig = Base.encode64(:crypto.sign(:eddsa, :none, json, [priv, :ed25519])) <> "\n"

    # Check the result exactly as Lepton will, with the published public key.
    pub = File.read!(@pub) |> String.trim() |> Base.decode64!()

    case Lepton.Official.verify(json, sig, pub) do
      {:ok, _} -> :ok
      {:error, e} -> Mix.raise("the signed list does not verify (#{e}) - is the key in #{key_source()} the key for #{@pub}?")
    end

    File.write!(@manifest, json)
    File.write!(@manifest <> ".sig", sig)
    info("#{message}; signed list ##{data["serial"]}")
    info("publish it: commit and push #{Path.dirname(@manifest)}/ (official.json, official.json.sig)")
  end

  # Readable, stable JSON (fixed key order) - the exact bytes are signed.
  defp encode(%{"schema" => schema, "serial" => serial, "issued" => issued, "maintainers" => maintainers, "apps" => apps}) do
    app_keys = ~w(package version checksum replaces description deps)
    pin_keys = ~w(package version checksum)

    obj = fn map, keys -> "{" <> Enum.map_join(Enum.filter(keys, &Map.has_key?(map, &1)), ", ", &"#{JSON.encode!(&1)}: #{value(map[&1], pin_keys)}") <> "}" end

    apps_json = if apps == [], do: "[]", else: "[\n    " <> Enum.map_join(apps, ",\n    ", &obj.(&1, app_keys)) <> "\n  ]"

    """
    {
      "_comment": #{JSON.encode!(@trust)},
      "schema": #{schema},
      "serial": #{serial},
      "issued": #{JSON.encode!(issued)},
      "maintainers": {"hex_organization": #{JSON.encode!(maintainers["hex_organization"])}},
      "apps": #{apps_json}
    }
    """
  end

  defp value(list, pin_keys) when is_list(list) do
    "[" <> Enum.map_join(list, ", ", fn
      %{} = m -> "{" <> Enum.map_join(pin_keys, ", ", &"#{JSON.encode!(&1)}: #{JSON.encode!(m[&1])}") <> "}"
      v -> JSON.encode!(v)
    end) <> "]"
  end

  defp value(v, _), do: JSON.encode!(v)

  # -- helpers -------------------------------------------------------------------------------------

  # -- the signing key --------------------------------------------------------------------------

  defp key_source, do: System.get_env("LEPTON_SIGNING_KEY") || "the Keychain (#{@keychain})"

  defp private_key do
    text =
      case System.get_env("LEPTON_SIGNING_KEY") do
        nil ->
          case System.cmd("security", ["find-generic-password", "-s", @keychain, "-w"], stderr_to_stdout: true) do
            {t, 0} -> t
            _ -> nil
          end

        path ->
          case File.read(path) do
            {:ok, t} -> t
            _ -> nil
          end
      end

    text && text |> String.trim() |> Base.decode64!()
  end

  defp private_key! do
    private_key() || Mix.raise("no signing key in #{key_source()} (mix lepton.official keygen, or set LEPTON_SIGNING_KEY)")
  end

  defp keychain_store!(secret) do
    args = ["add-generic-password", "-U", "-a", "lepton", "-s", @keychain, "-l", "Lepton official-updates signing key (Ed25519)", "-w", secret]

    case System.cmd("security", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> Mix.raise("could not store the key in the Keychain: #{out}")
    end
  end

  # -- hex.pm ownership ------------------------------------------------------------------------------

  # Every owner must be the organization or one of its members, so nobody
  # outside it can publish new versions of an official package.
  defp check_owners!(package, org) do
    members = MapSet.new(["#{org}" | Enum.map(hex_api!("/orgs/#{org}/members"), & &1["username"])])
    owners = Enum.map(hex_api!("/packages/#{package}/owners"), & &1["username"])

    case Enum.reject(owners, &MapSet.member?(members, &1)) do
      [] -> info("#{package} owners (#{Enum.join(owners, ", ")}) are all in the #{org} organization")
      outsiders -> Mix.raise("#{package} is also owned by #{Enum.join(outsiders, ", ")}, outside the #{org} organization - refusing")
    end
  end

  defp hex_api!(path) do
    token =
      with {:ok, terms} <- :file.consult(Path.expand("~/.hex/hex.config")),
           %{access_token: t} <- terms[:"$oauth_token"] do
        t
      else
        _ -> Mix.raise("not logged in to hex.pm - run `mix hex.user auth`")
      end

    :inets.start()
    :ssl.start()

    case :httpc.request(:get, {~c"https://hex.pm/api" ++ String.to_charlist(path), [{~c"authorization", String.to_charlist("Bearer " <> token)}, {~c"accept", ~c"application/json"}, {~c"user-agent", ~c"lepton-official"}]}, [ssl: Lepton.Git.Remote.ssl_opts([])], body_format: :binary) do
      {:ok, {{_, 200, _}, _, body}} -> JSON.decode!(body)
      {:ok, {{_, 401, _}, _, _}} -> Mix.raise("hex.pm login expired - run `mix hex.user auth`")
      {:ok, {{_, code, _}, _, _}} -> Mix.raise("hex.pm #{path}: HTTP #{code}")
      {:error, e} -> Mix.raise("hex.pm #{path}: #{inspect(e)}")
    end
  end

  defp release!(name, version) do
    case Lepton.Pkg.get("#{@api}/packages/#{name}/releases/#{version}") do
      {:ok, body} ->
        rel = JSON.decode!(body)
        if rel["retirement"], do: Mix.raise("#{name} #{version} is retired on hex.pm")
        rel

      {:error, e} ->
        Mix.raise("#{name} #{version}: #{e}")
    end
  end

  defp maybe_put(map, key, value, empty \\ nil)
  defp maybe_put(map, _key, value, empty) when value == empty, do: map
  defp maybe_put(map, key, value, _), do: Map.put(map, key, value)

  defp info(msg), do: Mix.shell().info([:cyan, "==> ", :reset, msg])
end
