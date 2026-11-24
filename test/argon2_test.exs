defmodule Lepton.Argon2Test do
  use ExUnit.Case

  alias Lepton.Argon2

  # RFC 9106, 5.3: Argon2id with a secret and associated data, four lanes.
  test "the RFC 9106 test vector for Argon2id" do
    tag = Argon2.hash(:binary.copy(<<1>>, 32), :binary.copy(<<2>>, 16), t: 3, m: 32, p: 4, length: 32, secret: :binary.copy(<<3>>, 8), ad: :binary.copy(<<4>>, 12))
    assert Base.encode16(tag, case: :lower) == "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"
  end

  test "BLAKE2b to other lengths (RFC 7693), as crypto's at 64 bytes" do
    assert Base.encode16(Argon2.blake2b("", 32), case: :lower) == "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"
    assert Base.encode16(Argon2.blake2b("abc", 32), case: :lower) == "bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319"
    long = String.duplicate("x", 300)
    assert Lepton.Argon2.Blake2b.hash(long, 64) == :crypto.hash(:blake2b, long)
  end

  test "different passwords, salts and costs give different keys; the same, the same" do
    a = Argon2.hash("password", "saltsaltsaltsalt", t: 1, m: 64)
    assert byte_size(a) == 32
    assert a == Argon2.hash("password", "saltsaltsaltsalt", t: 1, m: 64)
    refute a == Argon2.hash("passwore", "saltsaltsaltsalt", t: 1, m: 64)
    refute a == Argon2.hash("password", "saltsaltsaltsalu", t: 1, m: 64)
    refute a == Argon2.hash("password", "saltsaltsaltsalt", t: 2, m: 64)
  end
end
