defmodule Lepton.Persist.Check do
  @moduledoc """
  Checking the data partition's file system at boot, before it's mounted,
  when it needs it: `e2fsck`, which the image carries
  (`/usr/libexec/lepton/e2fsck`, from Alpine's e2fsprogs).

  The superblock says how the file system was left (`s_state`): *clean*
  (cleanly unmounted, no errors), or not (Lepton stopped without
  unmounting it: a crash, power cut, a VM stopped from outside; or the
  kernel found an inconsistency, and set the "errors" flag, which only a
  check clears). A clean one is left alone. Otherwise `e2fsck -p` (the
  automatic, safe repairs) runs; if it leaves something it won't fix by
  itself, `e2fsck -fy` repairs that too (nobody is there to answer its
  questions at boot). What it says goes to the log.

  Growing the file system (`Lepton.Persist.Grow`) needs this: the kernel
  won't grow a file system with the errors flag set.
  """

  require Logger

  @e2fsck "/usr/libexec/lepton/e2fsck"
  # s_state's bits
  @valid 1
  @errors 2

  def available?, do: File.exists?(e2fsck())
  defp e2fsck, do: Application.get_env(:lepton, :e2fsck, @e2fsck)

  @doc "The superblock's state: `:clean`, `:unclean` (not unmounted cleanly), `:errors`, or `{:error, why}`."
  def state(dev) do
    with {:ok, f} <- :file.open(String.to_charlist(dev), [:read, :raw, :binary]),
         {:ok, sb} <- :file.pread(f, 1024, 1024) do
      :file.close(f)

      case sb do
        <<_::binary-size(56), 0xEF53::little-16, state::little-16, _::binary>> ->
          cond do
            Bitwise.band(state, @errors) != 0 -> :errors
            Bitwise.band(state, @valid) == 0 -> :unclean
            true -> :clean
          end

        _ ->
          {:error, "no ext2 file system on #{dev}"}
      end
    else
      {:error, why} -> {:error, inspect(why)}
      :eof -> {:error, "no ext2 file system on #{dev}"}
    end
  end

  @doc """
  Check `dev` if it needs it (`force: true`: even when clean). Returns
  `:clean` (nothing to do), `{:checked, status, output}` (e2fsck's exit
  status: 0 nothing wrong, 1 repaired), `{:failed, status, output}`
  (errors left, or it couldn't run) or `{:error, why}`.
  """
  def run(dev, opts \\ []) do
    force = opts[:force] == true

    case state(dev) do
      {:error, _} = e ->
        e

      :clean when not force ->
        :clean

      st ->
        if available?() do
          Logger.info("check: #{dev} is #{describe(st)}: checking it (e2fsck)")
          {status, out} = e2fsck(["-p", dev])

          {status, out} =
            if Bitwise.band(status, 4) != 0 do
              Logger.warning("check: e2fsck -p left errors on #{dev}; repairing them (e2fsck -fy)")
              {s2, out2} = e2fsck(["-f", "-y", dev])
              {s2, out <> out2}
            else
              {status, out}
            end

          for line <- String.split(out, "\n", trim: true), do: Logger.info("e2fsck: " <> line)
          if Bitwise.band(status, 4 + 8 + 16 + 32 + 128) == 0, do: {:checked, status, out}, else: {:failed, status, out}
        else
          {:error, "e2fsck isn't in this image"}
        end
    end
  end

  defp describe(:errors), do: "marked as having errors"
  defp describe(:unclean), do: "not cleanly unmounted"
  defp describe(:clean), do: "clean"

  # {exit status, what it said}
  defp e2fsck(args) do
    {out, status} = System.cmd(e2fsck(), args, stderr_to_stdout: true, env: [{"E2FSCK_CONFIG", "/dev/null"}])
    {status, out}
  rescue
    e -> {8, Exception.message(e)}
  end
end
