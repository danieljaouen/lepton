defmodule LeptonBuild.Dotfiles do
  @moduledoc """
  Installs a dotfiles repository into the image's home directory, following
  the repository's own `locations/` convention (see its README):

    * `locations/NAME.symlink -> ../topics/...` becomes `~/.NAME`
    * `locations/NAME.directory.symlink -> NAME` creates `~/.NAME/` and the
      entries of `locations/NAME/` are installed inside it (without a dot)
    * plain files are copied, not symlinked, because the image is read from
      a cpio archive and must be self-contained
  """

  @doc "Returns `[{relative_path_in_home, contents | :dir}]`."
  def entries(repo) do
    locations = Path.join(repo, "locations")

    if File.dir?(locations) do
      walk(locations, "", true)
    else
      []
    end
  end

  defp walk(dir, prefix, top?) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      full = Path.join(dir, name)

      cond do
        String.ends_with?(name, ".directory.symlink") ->
          base = String.replace_suffix(name, ".directory.symlink", "")
          target = home_name(prefix, base, top?)
          sub = Path.join(dir, base)
          nested = if File.dir?(sub), do: walk(sub, target, false), else: []
          [{target, :dir} | nested]

        String.ends_with?(name, ".symlink") ->
          base = String.replace_suffix(name, ".symlink", "")

          case File.read(full) do
            {:ok, contents} -> [{home_name(prefix, base, top?), contents}]
            # Dangling links (e.g. placeholders for machine-local files) are skipped.
            {:error, _} -> []
          end

        true ->
          []
      end
    end)
  end

  defp home_name("", base, true), do: "." <> base
  defp home_name(prefix, base, _), do: Path.join(prefix, base)
end
