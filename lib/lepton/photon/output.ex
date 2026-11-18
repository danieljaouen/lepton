defmodule Lepton.Photon.Output do
  @moduledoc """
  Where Photon's pixels go: the Linux framebuffer (`/dev/fb0`, which
  virtio-gpu and simpledrm provide), or a plain file of the same layout
  (tests, and running on a development machine).

  Pixels are XRGB8888, little-endian (bytes B, G, R, X), which is both the
  framebuffer's format and `wl_shm`'s. Rows are written with `pwrite`, so
  no `mmap` is needed.
  """

  defstruct [:file, :path, :width, :height, :stride]

  @doc """
  Describe the framebuffer device. Like `file/3`, this only checks it can
  be opened: raw files belong to the process that opens them, so Photon
  calls `open/1` itself.
  """
  def framebuffer(dev \\ "/dev/fb0") do
    sys = Path.join("/sys/class/graphics", Path.basename(dev))

    with {:ok, size} <- File.read(Path.join(sys, "virtual_size")),
         {:ok, bpp} <- File.read(Path.join(sys, "bits_per_pixel")),
         {:ok, stride} <- File.read(Path.join(sys, "stride")),
         [w, h] <- size |> String.trim() |> String.split(",") |> Enum.map(&String.to_integer/1),
         {32, _} <- {String.to_integer(String.trim(bpp)), bpp},
         {:ok, file} <- :file.open(String.to_charlist(dev), [:raw, :binary, :read, :write]) do
      :file.close(file)
      {:ok, %__MODULE__{path: dev, width: w, height: h, stride: String.to_integer(String.trim(stride))}}
    else
      {bpp, _} when is_integer(bpp) -> {:error, "#{dev} is #{bpp} bits per pixel; Photon needs 32"}
      {:error, :enoent} -> {:error, "no framebuffer (#{dev}): the VM needs a display (virtio-gpu or ramfb)"}
      {:error, reason} -> {:error, "#{dev}: #{inspect(reason)}"}
      _ -> {:error, "#{dev}: unexpected framebuffer description in #{sys}"}
    end
  end

  @doc "A file-backed output of `width` x `height` pixels."
  def file(path, width, height) do
    File.write!(path, :binary.copy(<<0, 0, 0, 0>>, width * height))
    %__MODULE__{path: path, width: width, height: height, stride: width * 4}
  end

  @doc "Open the output for writing, in the calling process."
  def open(%__MODULE__{path: path} = out) do
    {:ok, file} = :file.open(String.to_charlist(path), [:raw, :binary, :read, :write])
    %{out | file: file}
  end

  @doc "Write rows: `[{x, y, pixels}]`."
  def write(%__MODULE__{file: f, stride: stride}, rows) do
    :file.pwrite(f, for({x, y, px} <- rows, do: {y * stride + x * 4, px}))
  end

  @doc "Read a rectangle back as one binary of `w * h` pixels (opening the output if this process hasn't)."
  def read(%__MODULE__{file: nil} = out, x, y, w, h) do
    out = open(out)

    try do
      read(out, x, y, w, h)
    after
      close(out)
    end
  end

  def read(%__MODULE__{file: f, stride: stride}, x, y, w, h) do
    {:ok, rows} = :file.pread(f, for(r <- y..(y + h - 1)//1, do: {r * stride + x * 4, w * 4}))
    IO.iodata_to_binary(rows)
  end

  def close(%__MODULE__{file: f}), do: :file.close(f)

  @doc """
  Turn the kernel's text console on the framebuffer off (`false`) or back
  on (`true`): unbinding fbcon stops it drawing over Photon; binding it
  again redraws the console as it was.
  """
  def text_console(on?) do
    for dir <- Path.wildcard("/sys/class/vtconsole/vtcon*"),
        String.contains?(File.read!(Path.join(dir, "name")), "frame buffer") do
      File.write(Path.join(dir, "bind"), if(on?, do: "1", else: "0"))
    end

    :ok
  end

  @doc "Encode `w` x `h` XRGB pixels as a PNG."
  def png(pixels, w, h) do
    rows = for <<row::binary-size(^w * 4) <- pixels>>, do: [0 | for(<<b, g, r, _ <- row>>, do: <<r, g, b>>)]
    z = :zlib.compress(IO.iodata_to_binary(rows))
    IO.iodata_to_binary([<<0x89, "PNG\r\n", 0x1A, "\n">>, chunk("IHDR", <<w::32, h::32, 8, 2, 0, 0, 0>>), chunk("IDAT", z), chunk("IEND", "")])
  end

  defp chunk(type, data), do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
end
