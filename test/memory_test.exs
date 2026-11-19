defmodule Lepton.MemoryTest do
  use ExUnit.Case, async: true

  alias Lepton.Memory

  test "reads /proc/meminfo and knows when memory is short" do
    mem = Memory.parse("MemTotal:        4000872 kB\nMemFree:          295220 kB\nMemAvailable:     229408 kB\n")
    assert mem == %{total: 4_000_872, available: 229_408}
    assert Memory.threshold(4_000_872) == 200_043
    refute Memory.low?(mem)
    assert Memory.low?(%{mem | available: 150_000})
    # Small machines keep at least 160 MiB.
    assert Memory.threshold(1_000_000) == 160 * 1024
    assert Memory.parse("MemTotal: 1 kB\n") == nil
    refute Memory.low?(nil)
  end

  test "stops the largest of Firefox's tabs, else the largest app program" do
    main = %{pid: 10, rss: 900_000, cmdline: "/apps/firefox/usr/lib/firefox/firefox --profile p"}
    gpu = %{pid: 11, rss: 800_000, cmdline: "/apps/firefox/usr/lib/firefox/firefox -contentproc -ipcHandle 0 rdd"}
    tab = %{pid: 12, rss: 300_000, cmdline: "/apps/firefox/usr/lib/firefox/firefox -contentproc -isForBrowser -prefsHandle 0 tab"}
    big_tab = %{tab | pid: 13, rss: 500_000}
    assert Memory.victim([main, gpu, tab, big_tab]).pid == 13
    assert Memory.victim([main, gpu]).pid == 10
    assert Memory.victim([]) == nil
  end
end
