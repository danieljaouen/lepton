defmodule Lepton.Ctx do
  @moduledoc """
  The execution context of a Lepton process: what Unix keeps in the process
  table entry (cwd, environment, file descriptors 0-2, controlling tty).

  The BEAM has a single node-wide working directory, so Lepton never calls
  `File.cd/1`: every path is resolved against `ctx.cwd` with `path/2`.
  """

  defstruct cwd: "/",
            env: %{},
            stdin: nil,
            stdout: nil,
            stderr: nil,
            tty: nil,
            shell: nil,
            pid: nil,
            # Who this process runs as (Lepton.Users); not the USER variable.
            user: "root"

  def path(%__MODULE__{cwd: cwd, env: env}, p) do
    home = Map.get(env, "HOME", "/root")

    p =
      cond do
        p == "~" -> home
        String.starts_with?(p, "~/") -> home <> String.slice(p, 1..-1//1)
        true -> p
      end

    Path.expand(p, cwd)
  end

  def get_env(%__MODULE__{env: env}, key, default \\ nil), do: Map.get(env, key, default)

  def home(ctx), do: get_env(ctx, "HOME", "/root")

  @doc "Shorten a path for display (`/root/src` -> `~/src`)."
  def tildify(ctx, path) do
    home = home(ctx)

    cond do
      path == home -> "~"
      String.starts_with?(path, home <> "/") -> "~" <> String.replace_prefix(path, home, "")
      true -> path
    end
  end
end

defmodule Lepton.IO do
  @moduledoc """
  Byte-oriented I/O helpers over Erlang I/O devices (TTYs, pipes, files).

  A write to a closed pipe exits the calling process with `:epipe`, the way
  SIGPIPE terminates a Unix process.
  """

  alias Lepton.Ctx

  def write(%Ctx{stdout: dev}, data), do: write(dev, data)

  def write(dev, data) do
    case safe(fn -> IO.binwrite(dev, data) end) do
      :ok -> :ok
      {:error, _} -> exit(:epipe)
    end
  end

  def puts(ctx_or_dev, data), do: write(ctx_or_dev, [data, "\n"])

  def err(%Ctx{stderr: dev}, data), do: write(dev, [data, "\n"])

  @doc "Reads one line (including its trailing newline) or returns :eof."
  def read_line(%Ctx{stdin: dev}), do: read_line(dev)
  def read_line(nil), do: :eof

  def read_line(dev) do
    case safe(fn -> IO.binread(dev, :line) end) do
      data when is_binary(data) -> data
      _ -> :eof
    end
  end

  def read_chars(dev, n) do
    case safe(fn -> IO.binread(dev, n) end) do
      data when is_binary(data) -> data
      _ -> :eof
    end
  end

  @doc "Lazily stream lines from a device."
  def lines(%Ctx{stdin: dev}), do: lines(dev)

  def lines(dev) do
    Stream.unfold(:go, fn _ ->
      case read_line(dev) do
        :eof -> nil
        line -> {line, :go}
      end
    end)
  end

  def read_all(dev), do: dev |> lines() |> Enum.join()

  defp safe(fun) do
    fun.()
  rescue
    e in ErlangError -> {:error, e.original}
    _ -> {:error, :io}
  catch
    :exit, _ -> {:error, :terminated}
  end
end
