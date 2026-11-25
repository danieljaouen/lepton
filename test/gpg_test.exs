defmodule Lepton.GpgTest do
  use ExUnit.Case
  import Lepton.TestHelpers

  alias Lepton.PGP.{Crypto, Packet}

  # What GnuPG 2.4.9 made (test/fixtures/gpg): Bob's key (Ed25519 and
  # Curve25519, no passphrase), a message encrypted to him (GnuPG's AEAD
  # packet, OCB), one with a passphrase, and signatures of message.txt.
  @fixtures Path.join(__DIR__, "fixtures/gpg")

  defp home do
    h = tmp_dir("gpghome")
    File.cp_r!(@fixtures, h)
    h
  end

  # gpg as a user: {stdout, status}; stderr kept apart.
  defp gpg(args, h, opts \\ []) do
    {:ok, err} = StringIO.open("")
    stdin = if opts[:stdin], do: elem(StringIO.open(opts[:stdin]), 1)
    {out, status} = sh("gpg " <> args, home: h, cwd: h, env: %{"GNUPGHOME" => Path.join(h, ".gnupg")}, stdin: stdin, stderr: err)
    {out, status, elem(StringIO.contents(err), 1)}
  end

  test "the building blocks: OCB (RFC 7253), AES key wrap (RFC 3394), armor's CRC-24" do
    k = Base.decode16!("000102030405060708090A0B0C0D0E0F")
    assert {:ok, ""} == Crypto.ocb_decrypt(7, k, Base.decode16!("BBAA99887766554433221100"), "", Base.decode16!("785407BFFFC8AD9EDCC5520AC9111EE6"))
    p = Base.decode16!("000102030405060708090A0B0C0D0E0F1011121314151617")
    assert {:ok, ^p} = Crypto.ocb_decrypt(7, k, Base.decode16!("BBAA99887766554433221107"), p, Base.decode16!("1CA2207308C87C010756104D8840CE1952F09673A448A122C92C62241051F57356D7F3C90BB0E07F"))
    assert :error == Crypto.ocb_decrypt(7, k, Base.decode16!("BBAA99887766554433221100"), "", Base.decode16!("785407BFFFC8AD9EDCC5520AC9111EE7"))
    assert Base.encode16(Crypto.wrap(k, Base.decode16!("00112233445566778899AABBCCDDEEFF"))) == "1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5"
    armored = Packet.armor("MESSAGE", "some bytes")
    assert {:ok, [{"MESSAGE", "some bytes"}]} = Packet.dearmor(armored)
    assert {:error, _} = Packet.dearmor(String.replace(armored, "c29tZSBieXRlcw", "c29tZSBieXRld"))
  end

  test "GnuPG's key, messages and signatures: imported, decrypted (AEAD and passphrase), verified" do
    h = home()
    {_, 0, err} = gpg("--import bob.pub.asc", h)
    assert err =~ "public key \"Real Bob <bob@example.com>\" imported"
    {out, 0, _} = gpg("--list-keys", h)
    assert out =~ "pub   ed25519 2026-11-25 [SC]" and out =~ "8C4B3AC2817BB4459DD0852AFF1DE4EF4EE9B36A" and out =~ "sub   cv25519 2026-11-25 [E]"

    for sig <- ["message.txt.asc", "clearsigned.asc", "signed.asc"] do
      {_, status, err} = gpg("--verify #{sig}", h)
      assert status == 0 and err =~ ~s(Good signature from "Real Bob <bob@example.com>" [unknown]), sig
    end

    message = File.read!(Path.join(@fixtures, "message.txt"))
    assert {^message, 0, _} = gpg("-d signed.asc", h)
    File.write!(Path.join(h, "message.txt"), message <> "changed")
    assert {_, 1, err} = gpg("--verify message.txt.asc message.txt", h)
    assert err =~ "BAD signature"

    assert {^message, 0, _} = gpg("--batch --passphrase 'fixture pass' -d symmetric.asc", h)
    assert {_, 2, err} = gpg("--batch --passphrase wrong -d symmetric.asc", h)
    assert err =~ "decryption failed"
    assert {_, 2, err} = gpg("-d to-bob.aead.asc", h)
    assert err =~ "no secret key"
    {_, 0, err} = gpg("--import bob.sec.asc", h)
    assert err =~ "secret key imported"
    {out, 0, err} = gpg("-d to-bob.aead.asc", h)
    assert out == message and err =~ "encrypted with cv25519 key, ID 851DAEE02EED5495"
  end

  test "keys made here: listed, exported and imported elsewhere; encrypt, sign, verify, decrypt between two homes" do
    alice = home()
    bob = home()
    {out, 0, _} = gpg("--batch --passphrase apw --quick-gen-key 'Alice <alice@lepton.test>' default default 1y", alice)
    assert out =~ "public and secret key created" and out =~ "[expires: "
    assert File.stat!(Path.join(alice, ".gnupg")).mode |> Bitwise.band(0o777) == 0o700
    {out, 0, _} = gpg("-K", alice)
    assert out =~ "sec   ed25519" and out =~ "uid           [ultimate] Alice <alice@lepton.test>" and out =~ "ssb   cv25519"
    {_, 0, _} = gpg("-a -o alice.asc --export alice@lepton.test", alice)
    File.cp!(Path.join(alice, "alice.asc"), Path.join(bob, "alice.asc"))
    {_, 0, _} = gpg("--import alice.asc", bob)

    File.write!(Path.join(bob, "secret.txt"), "for Alice only\n")
    {_, 0, _} = gpg("-e -r alice@lepton.test secret.txt", bob)
    assert "-----BEGIN PGP MESSAGE-----" <> _ = File.read!(Path.join(bob, "secret.txt.gpg")) |> then(fn bin -> Packet.armor("MESSAGE", bin) end)
    File.cp!(Path.join(bob, "secret.txt.gpg"), Path.join(alice, "secret.txt.gpg"))
    assert {"for Alice only\n", 0, err} = gpg("--batch --passphrase apw -d secret.txt.gpg", alice)
    assert err =~ "encrypted with cv25519 key"
    assert {_, 2, err} = gpg("--batch --passphrase nope -d secret.txt.gpg", alice)
    assert err =~ "Bad passphrase"

    # Signed by Alice, checked by Bob (who has her public key only).
    File.write!(Path.join(alice, "note.txt"), "Signed text\n- with a dash\n")
    {_, 0, _} = gpg("--batch --passphrase apw --clearsign note.txt", alice)
    {_, 0, _} = gpg("--batch --passphrase apw -b note.txt", alice)
    for f <- ["note.txt", "note.txt.asc", "note.txt.sig"], do: File.cp!(Path.join(alice, f), Path.join(bob, f))
    assert {_, 0, err} = gpg("--verify note.txt.asc", bob)
    assert err =~ ~s(Good signature from "Alice <alice@lepton.test>" [unknown])
    assert {_, 0, _} = gpg("--verify note.txt.sig note.txt", bob)
    # Someone without her key can't check it.
    stranger = home()
    File.cp!(Path.join(alice, "note.txt.asc"), Path.join(stranger, "note.txt.asc"))
    assert {_, 2, err} = gpg("--verify note.txt.asc", stranger)
    assert err =~ "No public key"

    # Signed and encrypted, from standard input to standard output.
    {msg, 0, _} = gpg("--batch --passphrase apw -a -s -e -r alice@lepton.test", alice, stdin: "both\n")
    assert msg =~ "-----BEGIN PGP MESSAGE-----"
    assert {"both\n", 0, err} = gpg("--batch --passphrase apw -d", alice, stdin: msg)
    assert err =~ "Good signature" and err =~ "[ultimate]"
    # A changed message: refused.
    {bin, 0, _} = gpg("--batch --passphrase apw -s -e -r alice@lepton.test", alice, stdin: "x\n")
    n = byte_size(bin) - 30
    <<head::binary-size(n), b, tail::binary>> = bin
    assert {_, 2, _} = gpg("--batch --passphrase apw -d", alice, stdin: head <> <<Bitwise.bxor(b, 1)>> <> tail)

    # Symmetric, an existing file not overwritten without --yes.
    File.rm!(Path.join(bob, "secret.txt.gpg"))
    {_, 0, _} = gpg("--batch --passphrase sym -c secret.txt", bob)
    assert {"for Alice only\n", 0, _} = gpg("--batch --passphrase sym -d secret.txt.gpg", bob)
    assert {_, 2, err} = gpg("--batch --passphrase sym -c secret.txt", bob)
    assert err =~ "exists"
    assert {_, 0, _} = gpg("--batch --yes --passphrase sym -c secret.txt", bob)

    # Deleting: the secret key first.
    assert {_, 2, err} = gpg("--batch --yes --delete-keys alice@lepton.test", alice)
    assert err =~ "--delete-secret-keys"
    assert {_, 0, _} = gpg("--batch --yes --delete-secret-and-public-key alice@lepton.test", alice)
    assert {"", 0, _} = gpg("-k", alice)
  end

  test "usage: unknown options, no recipients, nothing to verify" do
    h = home()
    assert {_, 2, err} = gpg("--frobnicate", h)
    assert err =~ "invalid option"
    assert {_, 2, err} = gpg("-e message.txt", h)
    assert err =~ "no recipients"
    assert {_, 2, err} = gpg("-e -r nobody@nowhere message.txt", h)
    assert err =~ "No public key"
    assert {out, 0, _} = gpg("--version", h)
    assert out =~ "OpenPGP"
  end
end
