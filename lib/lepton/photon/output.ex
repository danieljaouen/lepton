defmodule Lepton.Photon.Output do
  @moduledoc """
  Where Photon's pixels go: the Linux framebuffer (`/dev/fb0`, which
  virtio-gpu and simpledrm provide), or a plain file of the same layout
  (tests, and running on a development machine).

  Pixels are XRGB8888, little-endian (bytes B, G, R, X), which is both the
  framebuffer's usual format and `wl_shm`'s. A 16-bit framebuffer (RGB565:
  USB display adapters, whose drivers pick 16 bits to save bandwidth)
  gets its rows converted as they are written. Rows are written with
  `pwrite`, so no `mmap` is needed.
  """

  import Bitwise

  defstruct [:file, :path, :width, :height, :stride, bpp: 32]

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
         {bpp, _} when bpp in [16, 32] <- {String.to_integer(String.trim(bpp)), bpp},
         {:ok, file} <- :file.open(String.to_charlist(dev), [:raw, :binary, :read, :write]) do
      :file.close(file)
      {:ok, %__MODULE__{path: dev, width: w, height: h, stride: String.to_integer(String.trim(stride)), bpp: bpp}}
    else
      {bpp, _} when is_integer(bpp) -> {:error, "#{dev} is #{bpp} bits per pixel; Photon needs 32 or 16"}
      {:error, :enoent} -> {:error, "no framebuffer (#{dev}): the VM needs a display (virtio-gpu or ramfb)"}
      {:error, reason} -> {:error, "#{dev}: #{inspect(reason)}"}
      _ -> {:error, "#{dev}: unexpected framebuffer description in #{sys}"}
    end
  end

  @doc """
  The framebuffer devices, `/dev/fb0` first: the VM's display, a second
  virtual display, or a USB display adapter (`udl`, `gud`).
  """
  def framebuffers do
    Path.wildcard("/sys/class/graphics/fb*")
    |> Enum.map(&Path.basename/1)
    |> Enum.flat_map(fn "fb" <> n -> case Integer.parse(n) do
        {i, ""} -> [{i, "/dev/fb#{i}"}]
        _ -> []
      end end)
    |> Enum.sort()
    |> Enum.map(&elem(&1, 1))
  end

  @doc """
  Switch a framebuffer's display on. The kernel sets a DRM device's mode
  for its framebuffer when the framebuffer's settings are applied, which
  the text console does for `/dev/fb0` only. Writing the current depth
  back through sysfs applies them for another display.
  """
  def activate(%__MODULE__{path: "/dev/fb" <> _ = dev, bpp: bpp}) do
    File.write(Path.join(["/sys/class/graphics", Path.basename(dev), "bits_per_pixel"]), to_string(bpp))
    :ok
  end

  def activate(_out), do: :ok

  @doc "Which driver a framebuffer belongs to (`virtio_gpu`, `udl`, `gud`, ...), if the kernel says."
  def driver(dev) do
    sys = Path.join("/sys/class/graphics", Path.basename(dev))

    case File.read(Path.join(sys, "name")) do
      {:ok, name} -> name |> String.trim() |> String.replace_suffix("drmfb", "") |> String.replace_suffix("fb", "")
      _ -> nil
    end
  end

  @doc "A file-backed output of `width` x `height` pixels (`bpp`: 32 or 16)."
  def file(path, width, height, bpp \\ 32) do
    File.write!(path, :binary.copy(<<0>>, width * height * div(bpp, 8)))
    %__MODULE__{path: path, width: width, height: height, stride: width * div(bpp, 8), bpp: bpp}
  end

  @doc "Open the output for writing, in the calling process."
  def open(%__MODULE__{path: path} = out) do
    {:ok, file} = :file.open(String.to_charlist(path), [:raw, :binary, :read, :write])
    %{out | file: file}
  end

  @doc "Write rows: `[{x, y, pixels}]`."
  def write(%__MODULE__{file: f, stride: stride, bpp: 16}, rows) do
    :file.pwrite(f, for({x, y, px} <- rows, do: {y * stride + x * 2, to_rgb565(px)}))
  end

  def write(%__MODULE__{file: f, stride: stride}, rows) do
    :file.pwrite(f, for({x, y, px} <- rows, do: {y * stride + x * 4, px}))
  end

  @doc "XRGB8888 pixels as RGB565."
  def to_rgb565(px), do: for(<<b, g, r, _ <- px>>, into: <<>>, do: <<(r >>> 3 <<< 11 ||| g >>> 2 <<< 5 ||| b >>> 3)::little-16>>)

  @doc "RGB565 pixels as XRGB8888 (each channel's top bits repeated into the bottom)."
  def from_rgb565(px) do
    for <<v::little-16 <- px>>, into: <<>> do
      {r, g, b} = {v >>> 11, v >>> 5 &&& 0x3F, v &&& 0x1F}
      <<b <<< 3 ||| b >>> 2, g <<< 2 ||| g >>> 4, r <<< 3 ||| r >>> 2, 255>>
    end
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

  def read(%__MODULE__{file: f, stride: stride, bpp: bpp}, x, y, w, h) do
    size = div(bpp, 8)
    {:ok, rows} = :file.pread(f, for(r <- y..(y + h - 1)//1, do: {r * stride + x * size, w * size}))
    data = IO.iodata_to_binary(rows)
    if bpp == 16, do: from_rgb565(data), else: data
  end

  def close(%__MODULE__{file: f}), do: :file.close(f)

  @doc "Fill the output with black."
  def clear(%__MODULE__{width: w, height: h} = out) do
    row = :binary.copy(<<0, 0, 0, 255>>, w)
    write(out, for(y <- 0..(h - 1)//1, do: {0, y, row}))
  end

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
