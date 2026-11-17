defmodule Lepton.Official do
  @moduledoc """
  Official app updates: hex.pm packages allowed to stand in for built-in
  commands.

  Anyone can publish to hex.pm, so a package name proves nothing. Instead,
  the Lepton project publishes a **signed list** at #{"https://trylepton.app/official.json"}
  (signature in `official.json.sig`, Ed25519) naming, for each official
  update, the exact hex package, version and tarball SHA-256, the built-in
  commands it may replace, and pinned dependencies. The public key is
  compiled into the OS (`/etc/lepton/official-key.pub` holds a copy).

  `lpm upgrade grep` only installs what the list names, and only if every
  tarball matches its pinned checksum - a look-alike package, or a new
  release pushed from a compromised hex.pm account, is refused. The
  built-in is never deleted: `lpm revert grep` brings it back, and
  `builtin grep` always runs it.

  The list also names its maintainers: the `lepton` organization on
  hex.pm (<https://hex.pm/orgs/lepton>). Every hex.pm owner of an official
  package must belong to it, which `mix lepton.official add` checks before
  signing, so publishing an official update takes both the organization and
  the signing key.

  Lists carry a `serial`; an older list than one already accepted is
  rejected, so a stale list can't resurrect a withdrawn update. The last
  verified list is cached for offline use.

  Manifest format (schema 1):

      {"schema": 1, "serial": 3, "issued": "2026-11-16",
       "maintainers": {"hex_organization": "lepton"},
       "apps": [{"package": "lepton_grep", "version": "1.2.0",
                 "checksum": "<sha256 of the hex tarball>",
                 "replaces": ["grep", "egrep"],
                 "description": "...",
                 "deps": [{"package": "...", "version": "...", "checksum": "..."}]}]}
  """

  @key_file Path.expand("../../rootfs/etc/lepton/official-key.pub", __DIR__)
  @external_resource @key_file
  @public_key (case File.read(@key_file) do
                 {:ok, text} -> Base.decode64!(String.trim(text))
                 _ -> nil
               end)

  @url "https://trylepton.app/official.json"

  def url, do: @url
  def public_key, do: @public_key

  @doc "Fetch, verify and cache the official list (falls back to the cached copy offline)."
  def fetch(get \\ &Lepton.Pkg.get/1) do
    with {:ok, json} <- get.(@url),
         {:ok, sig} <- get.(@url <> ".sig") do
      accept(json, sig)
    else
      {:error, e} ->
        case cached() do
          {:ok, manifest} -> {:ok, Map.put(manifest, :offline, e)}
          _ -> {:error, "cannot fetch the official list (#{e})"}
        end
    end
  end

  @doc "Verify `json` with signature `sig`, apply the rollback check and cache it."
  def accept(json, sig, key \\ @public_key) do
    with {:ok, manifest} <- verify(json, sig, key) do
      case cached(key) do
        {:ok, %{serial: old}} when manifest.serial < old ->
          {:error, "official list serial #{manifest.serial} is older than the one already accepted (#{old}) - refusing"}

        _ ->
          File.mkdir_p!(Lepton.Pkg.root())
          File.write!(cache_path(), json)
          File.write!(cache_path() <> ".sig", sig)
          {:ok, manifest}
      end
    end
  end

  @doc "The last verified list, if any."
  def cached(key \\ @public_key) do
    with {:ok, json} <- File.read(cache_path()),
         {:ok, sig} <- File.read(cache_path() <> ".sig") do
      verify(json, sig, key)
    else
      _ -> {:error, :none}
    end
  end

  defp cache_path, do: Path.join(Lepton.Pkg.root(), "official.json")

  @doc "Check the signature and shape of a list; returns the parsed manifest."
  def verify(_json, _sig, nil), do: {:error, "this system has no official signing key"}

  def verify(json, sig, key) do
    with {:ok, sig} <- Base.decode64(String.trim(sig)),
         true <- :crypto.verify(:eddsa, :none, json, sig, [key, :ed25519]) || {:error, "bad signature on the official list"},
         {:ok, data} <- JSON.decode(json) do
      parse(data)
    else
      :error -> {:error, "malformed signature on the official list"}
      {:error, %JSON.DecodeError{}} -> {:error, "official list is not valid JSON"}
      {:error, _} = e -> e
    end
  end

  defp parse(%{"schema" => 1, "serial" => serial, "apps" => apps} = data) when is_integer(serial) and is_list(apps) do
    apps = Enum.map(apps, &app/1)

    if Enum.all?(apps, &match?(%{}, &1)),
      do: {:ok, %{serial: serial, issued: data["issued"], maintainers: get_in(data, ["maintainers", "hex_organization"]), apps: apps}},
      else: {:error, "official list has a malformed entry"}
  end

  defp parse(_), do: {:error, "unsupported official list format"}

  defp app(%{"package" => p, "version" => v, "checksum" => c, "replaces" => r} = a) when is_list(r) do
    deps = Enum.map(a["deps"] || [], &pin/1)

    if pin(a) && Enum.all?(r, &is_binary/1) && Enum.all?(deps, & &1),
      do: %{package: p, version: v, checksum: String.downcase(c), replaces: r, description: a["description"], deps: deps},
      else: nil
  end

  defp app(_), do: nil

  defp pin(%{"package" => p, "version" => v, "checksum" => c}) when is_binary(p) and is_binary(v) and is_binary(c) do
    if String.match?(c, ~r/^[0-9a-fA-F]{64}$/) and match?({:ok, _}, Version.parse(v)),
      do: %{package: p, version: v, checksum: String.downcase(c)},
      else: nil
  end

  defp pin(_), do: nil

  @doc "The entry for a command name (`grep`) or package name (`lepton_grep`)."
  def find(%{apps: apps}, name), do: Enum.find(apps, &(&1.package == name or name in &1.replaces))
end
