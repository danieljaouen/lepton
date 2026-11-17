defmodule Mix.Tasks.Lepton.Official do
  @shortdoc "Manage the signed list of official app updates (lpm upgrade)"
  @moduledoc """
  Maintains `site/official.json` (+ `.sig`), the signed list that lets a
  hex.pm package stand in for a built-in command (see `Lepton.Official`).

      mix lepton.official keygen
      mix lepton.official list
      mix lepton.official add PACKAGE VERSION --replaces grep[,egrep] [--dep NAME@VERSION ...]
      mix lepton.official remove PACKAGE
      mix lepton.official sign

  `add` takes each tarball's SHA-256 from hex.pm and pins it. Every
  non-optional dependency (transitively) must be pinned with `--dep`, since
  lpm refuses unpinned code for official updates. Each change bumps the
  list's `serial` and re-signs it; commit and push the site to publish it.

  The private key lives outside the repository, in
  `~/.config/lepton/official-signing.key` (or `$LEPTON_SIGNING_KEY`); the
  public key is `rootfs/etc/lepton/official-key.pub` and is compiled into
  the OS. Keep a backup of the private key: losing it means generating a
  new one and shipping a new ISO.
  """
  use Mix.Task

  @pub "rootfs/etc/lepton/official-key.pub"
  @manifest "site/official.json"
  @api "https://hex.pm/api"
  @trust "Do not edit by hand: use `mix lepton.official` (the file is signed)."

  @impl true
  def run(args) do
    {opts, rest} = OptionParser.parse!(args, strict: [replaces: :string, dep: :keep, description: :string])

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
    path = key_path()
    if File.exists?(path), do: Mix.raise("#{path} already exists - refusing to overwrite a signing key")
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Base.encode64(priv) <> "\n")
    File.chmod!(path, 0o600)
    File.mkdir_p!(Path.dirname(@pub))
    File.write!(@pub, Base.encode64(pub) <> "\n")
    info("private key: #{path} (mode 600 - back it up somewhere safe)")
    info("public key:  #{@pub} (compiled into the OS; commit it and rebuild the ISO)")
    unless File.exists?(@manifest), do: update(& &1, "created an empty official list")
  end

  defp list do
    %{"serial" => serial, "issued" => issued, "apps" => apps} = read()
    info("official list ##{serial}, issued #{issued}")
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

  defp update(fun, message) do
    priv = private_key!()
    old = read()
    data = %{old | "serial" => old["serial"] + 1, "issued" => Date.to_iso8601(Date.utc_today()), "apps" => fun.(old["apps"])}
    json = encode(data)
    sig = Base.encode64(:crypto.sign(:eddsa, :none, json, [priv, :ed25519])) <> "\n"

    # Check the result exactly as Lepton will, with the published public key.
    pub = File.read!(@pub) |> String.trim() |> Base.decode64!()

    case Lepton.Official.verify(json, sig, pub) do
      {:ok, _} -> :ok
      {:error, e} -> Mix.raise("the signed list does not verify (#{e}) - is #{key_path()} the key for #{@pub}?")
    end

    File.write!(@manifest, json)
    File.write!(@manifest <> ".sig", sig)
    info("#{message}; signed list ##{data["serial"]}")
    info("publish it: commit and push #{Path.dirname(@manifest)}/ (official.json, official.json.sig)")
  end

  # Readable, stable JSON (fixed key order) - the exact bytes are signed.
  defp encode(%{"schema" => schema, "serial" => serial, "issued" => issued, "apps" => apps}) do
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

  defp key_path, do: System.get_env("LEPTON_SIGNING_KEY") || Path.expand("~/.config/lepton/official-signing.key")

  defp private_key! do
    case File.read(key_path()) do
      {:ok, text} -> text |> String.trim() |> Base.decode64!()
      _ -> Mix.raise("no signing key at #{key_path()} (mix lepton.official keygen, or set LEPTON_SIGNING_KEY)")
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
