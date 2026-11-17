# Host-side entry point (`mix test`). Inside Lepton, `lepton-test` loads the
# same *_test.exs files with its own runner (see Lepton.SelfTest).
exclude = [:network] ++ if(Lepton.Sys.native?(), do: [], else: [:native])
exclude = if File.dir?("dotfiles"), do: exclude, else: [:dotfiles | exclude]
ExUnit.start(exclude: exclude)
