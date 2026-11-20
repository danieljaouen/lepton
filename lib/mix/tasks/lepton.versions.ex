defmodule Mix.Tasks.Lepton.Versions do
  @shortdoc "Compare Lepton's kernel, OTP and Elixir with the newest available"
  @moduledoc """
  Compares `versions.toml` with what is available now:

    * the kernel: Alpine's `linux-lts` on Lepton's branch;
    * OTP: Homebrew's `erlang`, when builds.hex.pm has the same release
      for the image (the two must match);
    * Elixir: Homebrew's `elixir`.

  Options:

    * `--check`: exit with status 1 when one is newer (for the daily update);
    * `--write`: record the newest in `versions.toml`.

  Upgrading the build machine itself (`brew upgrade erlang elixir`) is
  left to the caller.
  """

  use Mix.Task
  alias LeptonBuild.Sources

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [check: :boolean, write: :boolean])
    :inets.start()
    :ssl.start()
    Sources.cache_dir() |> File.mkdir_p!()

    now = Sources.versions()
    brew = brew_versions()
    hex_otp = hex_otp_builds()

    latest = %{
      "kernel" => Sources.alpine_latest("main", "linux-lts") || now["kernel"],
      "otp" =>
        case "OTP-" <> (brew["erlang"] || "") do
          v -> if v in hex_otp, do: v, else: now["otp"]
        end,
      "elixir" => brew["elixir"] || now["elixir"]
    }

    if "OTP-#{brew["erlang"]}" not in hex_otp and brew["erlang"],
      do: Mix.shell().info("(Homebrew has OTP #{brew["erlang"]}, not yet on builds.hex.pm: waiting for it)")

    newer =
      for k <- ~w(kernel otp elixir) do
        mark = if latest[k] != now[k], do: "  <- newer", else: ""
        Mix.shell().info(String.pad_trailing(k, 8) <> String.pad_trailing(now[k], 16) <> latest[k] <> mark)
        if latest[k] != now[k], do: k
      end
      |> Enum.reject(&is_nil/1)

    if opts[:write] && newer != [] do
      text = File.read!("versions.toml")
      text = Enum.reduce(newer, text, fn k, t -> String.replace(t, ~s(#{k} = "#{now[k]}"), ~s(#{k} = "#{latest[k]}")) end)
      File.write!("versions.toml", text)
      Mix.shell().info("versions.toml: #{Enum.join(newer, ", ")} updated")
    end

    if opts[:check] && newer != [], do: exit({:shutdown, 1})
  end

  defp brew_versions do
    case System.cmd("brew", ["info", "--json=v2", "erlang", "elixir"], stderr_to_stdout: false) do
      {json, 0} -> Map.new(JSON.decode!(json)["formulae"], &{&1["name"], &1["versions"]["stable"]})
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp hex_otp_builds do
    Sources.http_get!("#{Sources.otp_url()}/builds.txt")
    |> String.split("\n")
    |> Enum.map(&(String.split(&1, " ") |> hd()))
  end
end
