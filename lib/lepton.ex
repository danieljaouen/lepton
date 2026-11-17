defmodule Lepton do
  @moduledoc """
  Lepton OS - a Unix-like operating system for aarch64 whose userland is
  written in Elixir. See README.md.
  """

  @doc "Credits shown by the `credits` command and in `neofetch`."
  def credits do
    """
    Lepton OS was designed and written by Claude (Anthropic's Claude Opus 5.5,
    an AI model), working in Claude Code at the direction of Daniel Jaouen.

    It stands on the shoulders of:
      Linux (kernel)            Erlang/OTP and ERTS (runtime)
      Elixir (language)         Alpine Linux (kernel packaging, busybox, CA bundle)
      Debian (GRUB EFI build)   Ubuntu (glibc and runtime libraries)
      Hex.pm (packages via lpm, prebuilt OTP)
    """
  end
end
