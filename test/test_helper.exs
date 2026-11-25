# Host-side entry point (`mix test`). Inside Lepton, `lepton-test` loads the
# same *_test.exs files with its own runner (see Lepton.SelfTest).
exclude = [:network] ++ if(Lepton.Sys.native?(), do: [], else: [:native])
exclude = if Lepton.TestHelpers.dotfiles_repo(), do: exclude, else: [:dotfiles | exclude]
# The documentation sources and generator live in the repository only.
exclude = if File.dir?("docs") and Code.ensure_loaded?(LeptonBuild.Docs), do: exclude, else: [:docs | exclude]
ExUnit.start(exclude: exclude)
# An unpacked FFmpeg (no `ffmpeg` app installed): LEPTON_FFMPEG_PREFIX=DIR
# runs the media player's tests that need it.
if dir = System.get_env("LEPTON_FFMPEG_PREFIX"), do: Application.put_env(:lepton, :ffmpeg_prefix, dir)
# Likewise an unpacked Typst: LEPTON_TYPST_PREFIX=DIR.
if dir = System.get_env("LEPTON_TYPST_PREFIX"), do: Application.put_env(:lepton, :typst_prefix, dir)
# And an unpacked SNES app (libretro-bsnes, tcc, musl-dev): LEPTON_SNES_PREFIX=DIR.
if dir = System.get_env("LEPTON_SNES_PREFIX"), do: Application.put_env(:lepton, :snes_prefix, dir)
if dir = System.get_env("LEPTON_IMAGEMAGICK_PREFIX"), do: Application.put_env(:lepton, :imagemagick_prefix, dir)
