defmodule Lepton.TTY.Device do
  @moduledoc "TTY backend for a character device such as `/dev/tty1` or `/dev/ttyAMA0`."

  defstruct [:path, :out, :reader]

  def open(path, tty) do
    result = Lepton.Sys.tty_raw(path)

    if Lepton.Sys.cmdline_flag?("lepton.verbose=1") do
      {settings, _} = Lepton.Sys.shim("stty", ["-F", path, "-a"])
      Lepton.Init.say("stty raw #{path}: #{inspect(result)}\r\n#{settings}")
    end

    with {:ok, out} <- :file.open(path, [:write, :raw, :binary]) do
      reader = spawn_link(fn -> read_loop(path, tty) end)
      {:ok, %__MODULE__{path: path, out: out, reader: reader}}
    end
  end

  def size(%{path: path}) do
    case Lepton.Sys.tty_size(path) do
      {:ok, size} -> size
      :error -> nil
    end
  end

  def write(%{out: out}, data), do: :file.write(out, data)

  defp read_loop(path, tty) do
    case :file.open(path, [:read, :raw, :binary]) do
      {:ok, fd} ->
        loop(fd, tty)

      {:error, reason} ->
        Lepton.Init.say("tty: cannot open #{path} for reading: #{inspect(reason)}")
        send(tty, {:backend_closed, reason})
    end
  end

  # Raw-file reads in ERTS loop until the requested count is satisfied
  # (right for regular files, wrong for terminals), so read one byte at a
  # time: each read returns as soon as a key arrives.
  defp loop(fd, tty) do
    case :file.read(fd, 1) do
      {:ok, data} ->
        Lepton.TTY.input(tty, data)
        loop(fd, tty)

      :eof ->
        Process.sleep(50)
        loop(fd, tty)

      {:error, reason} ->
        Lepton.Init.say("tty: read error on #{inspect(fd)}: #{inspect(reason)}")
        send(tty, {:backend_closed, reason})
    end
  end
end

defmodule Lepton.TTY.Stdio do
  @moduledoc """
  TTY backend over the BEAM's own standard I/O, used in hosted mode
  (`mix lepton.shell` on a development machine).
  """

  defstruct [:user, :reader]

  def open(_arg, tty) do
    user = Process.whereis(:user) || Process.group_leader()
    _ = :shell.start_interactive({:noshell, :raw})
    :io.setopts(user, binary: true, encoding: :unicode)
    reader = spawn_link(fn -> loop(user, tty) end)
    {:ok, %__MODULE__{user: user, reader: reader}}
  end

  def size(%{user: user}) do
    with {:ok, cols} <- :io.columns(user), {:ok, rows} <- :io.rows(user) do
      {rows, cols}
    else
      _ -> nil
    end
  end

  # Output is UTF-8; send it as unicode chardata so `user` does not re-encode it.
  def write(%{user: user}, data), do: IO.write(user, data)

  defp loop(user, tty) do
    case IO.getn(user, "", 1) do
      data when is_binary(data) ->
        Lepton.TTY.input(tty, data)
        loop(user, tty)

      _ ->
        send(tty, {:backend_closed, :eof})
    end
  end
end

defmodule Lepton.TTY.Capture do
  @moduledoc "TTY backend that records output and accepts scripted input (tests)."

  use Agent

  def open(_arg, _tty) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, agent}
  end

  def size(_), do: {24, 80}
  def write(agent, data), do: Agent.update(agent, &[&1, data])
  def output(agent), do: Agent.get(agent, &IO.iodata_to_binary/1)
end
