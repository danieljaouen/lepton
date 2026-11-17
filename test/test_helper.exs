# Host-side entry point (`mix test`). Inside Lepton, `lepton-test` loads the
# same *_test.exs files with its own runner (see Lepton.SelfTest).
exclude = [:network] ++ if(Lepton.Sys.native?(), do: [], else: [:native])
exclude = if File.dir?("dotfiles"), do: exclude, else: [:dotfiles | exclude]
# The documentation sources and generator live in the repository only.
exclude = if File.dir?("docs") and Code.ensure_loaded?(LeptonBuild.Docs), do: exclude, else: [:docs | exclude]
ExUnit.start(exclude: exclude)
