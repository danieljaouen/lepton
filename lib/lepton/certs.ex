defmodule Lepton.Certs do
  @moduledoc """
  TLS certificates for `httpd`: made here, kept in `/var/lib/lepton/certs`
  (`NAME.crt`, `NAME.key`, PEM), and found by host name.

    * a **local CA** (as mkcert makes): Lepton's own certificate
      authority, made once, which signs certificates for development
      names (`myapp.local`, `localhost`, addresses). Lepton's own tools
      trust it, and Firefox does through a policy; another computer's
      browser trusts it once its certificate (`ca.crt`) is added there;
    * **self-signed** certificates;
    * **Let's Encrypt** (ACME, RFC 8555, with the HTTP-01 challenge that
      `httpd` answers), for names the internet can reach, and renewal;
    * certificates made elsewhere, imported.

  Keys are ECDSA P-256. Certificates and requests are written in DER
  here (`Lepton.Certs.DER`), signed with `:public_key`.
  """

  alias Lepton.Certs.DER

  def dir, do: Lepton.Persist.state_path("certs")
  def ca_dir, do: Path.join(dir(), "ca")
  def ca_cert_path, do: Path.join(ca_dir(), "ca.crt")
  def challenge_dir, do: Path.join(dir(), "acme-challenge")

  # -- keys and names ----------------------------------------------------------------------

  def generate_key, do: :public_key.generate_key({:namedCurve, :secp256r1})

  def key_pem(key), do: :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, key)])
  def cert_pem(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])

  def read_key(path) do
    with {:ok, pem} <- File.read(path), [entry | _] <- :public_key.pem_decode(pem) do
      {:ok, :public_key.pem_entry_decode(entry)}
    else
      _ -> {:error, "#{path}: not a private key"}
    end
  end

  def read_cert(path) do
    with {:ok, pem} <- File.read(path), [{:Certificate, der, _} | _] <- :public_key.pem_decode(pem) do
      {:ok, der}
    else
      _ -> {:error, "#{path}: not a certificate"}
    end
  end

  # The public point of a P-256 key.
  defp point({:ECPrivateKey, _, _priv, _params, pub, _}), do: pub

  defp spki(key) do
    DER.seq([DER.seq([DER.oid("1.2.840.10045.2.1"), DER.oid("1.2.840.10045.3.1.7")]), DER.bitstring(point(key))])
  end

  defp name(cn), do: DER.seq([DER.set([DER.seq([DER.oid("2.5.4.10"), DER.utf8("Lepton")])]), DER.set([DER.seq([DER.oid("2.5.4.3"), DER.utf8(cn)])])])

  # SubjectAltName: DNS names and IP addresses.
  defp san(hosts) do
    entries =
      for h <- hosts do
        case :inet.parse_address(String.to_charlist(h)) do
          {:ok, {a, b, c, d}} -> DER.implicit(7, <<a, b, c, d>>)
          {:ok, v6} -> DER.implicit(7, for(w <- Tuple.to_list(v6), into: <<>>, do: <<w::16>>))
          _ -> DER.implicit(2, h)
        end
      end

    ext("2.5.29.17", false, DER.seq(entries))
  end

  defp ext(oid, critical, value), do: DER.seq([DER.oid(oid)] ++ if(critical, do: [DER.bool(true)], else: []) ++ [DER.octet(value)])

  @ecdsa_sha256 "1.2.840.10045.4.3.2"

  defp sign(tbs, key), do: DER.seq([tbs, DER.seq([DER.oid(@ecdsa_sha256)]), DER.bitstring(:public_key.sign(tbs, :sha256, key))])

  defp key_id(key), do: :crypto.hash(:sha, point(key))

  @doc """
  A certificate: `subject` (a common name) and `hosts` (its names and
  addresses) for `key`, signed by `issuer` (`{issuer_cert_der,
  issuer_key}`, or nil for self-signed). `ca: true` makes a CA.
  """
  def certificate(key, cn, hosts, issuer, opts \\ []) do
    ca = opts[:ca] == true
    days = opts[:days] || if(ca, do: 3650, else: 397)
    now = System.os_time(:second)
    {issuer_name, issuer_key, issuer_kid} =
      case issuer do
        nil -> {name(cn), key, key_id(key)}
        {cert, ikey} -> {issuer_subject(cert), ikey, key_id(ikey)}
      end

    exts =
      [
        ext("2.5.29.19", true, DER.seq(if ca, do: [DER.bool(true)], else: [])),
        # keyUsage: CA: keyCertSign, cRLSign; else digitalSignature
        ext("2.5.29.15", true, if(ca, do: <<0x03, 0x02, 0x01, 0x06>>, else: <<0x03, 0x02, 0x07, 0x80>>)),
        ext("2.5.29.14", false, DER.octet(key_id(key))),
        ext("2.5.29.35", false, DER.seq([DER.implicit(0, issuer_kid)]))
      ] ++
        if(ca, do: [], else: [ext("2.5.29.37", false, DER.seq([DER.oid("1.3.6.1.5.5.7.3.1")])), san(hosts)])

    tbs =
      DER.seq([
        DER.explicit(0, DER.int(2)),
        DER.int(:crypto.strong_rand_bytes(15) |> :binary.decode_unsigned()),
        DER.seq([DER.oid(@ecdsa_sha256)]),
        issuer_name,
        DER.seq([DER.time(now - 3600), DER.time(now + days * 86_400)]),
        name(cn),
        spki(key),
        DER.explicit(3, DER.seq(exts))
      ])

    sign(tbs, issuer_key)
  end

  # The subject Name of a certificate (its DER), for the issuer field.
  defp issuer_subject(der) do
    {:Certificate, tbs, _, _} = :public_key.der_decode(:Certificate, der)
    :public_key.der_encode(:Name, elem(tbs, 6))
  end

  @doc "A certificate request (PKCS #10) for `hosts`, for ACME."
  def csr(key, hosts) do
    req = DER.seq([DER.oid("1.2.840.113549.1.9.14"), DER.set([DER.seq([san(hosts)])])])
    info = DER.seq([DER.int(0), name(hd(hosts)), spki(key), DER.context(0, req)])
    sign(info, key)
  end

  # -- the store ---------------------------------------------------------------------------------

  defp save(name, cert_pem, key, meta \\ nil) do
    File.mkdir_p!(dir())
    File.chmod(dir(), 0o755)
    File.write!(Path.join(dir(), name <> ".crt"), cert_pem)
    File.write!(Path.join(dir(), name <> ".key"), key_pem(key))
    File.chmod!(Path.join(dir(), name <> ".key"), 0o600)
    if meta, do: File.write!(Path.join(dir(), name <> ".acme"), JSON.encode!(meta))
    :ok
  end

  @doc "The certificates kept: `[%{name, hosts, not_after, issuer}]`."
  def list do
    for crt <- Path.wildcard(Path.join(dir(), "*.crt")) |> Enum.sort(), name = Path.basename(crt, ".crt"), {:ok, der} <- [read_cert(crt)] do
      Map.put(info(der), :name, name)
    end
  end

  @doc "What a certificate says: hosts, expiry (Unix time), issuer and subject names."
  def info(der) do
    otp = :public_key.pkix_decode_cert(der, :otp)
    tbs = elem(otp, 1)
    {:Validity, _from, to} = elem(tbs, 5)
    exts = elem(tbs, 10)

    hosts =
      case exts do
        list when is_list(list) ->
          for {:Extension, {2, 5, 29, 17}, _, names} <- list, entry <- names do
            case entry do
              {:dNSName, n} -> to_string(n)
              {:iPAddress, ip} when is_list(ip) -> ip |> :erlang.list_to_binary() |> ip_text()
              {:iPAddress, ip} -> ip_text(ip)
              _ -> nil
            end
          end
          |> Enum.reject(&is_nil/1)

        _ ->
          []
      end

    %{hosts: hosts, not_after: asn1_time(to), issuer: rdn_cn(elem(tbs, 4)), subject: rdn_cn(elem(tbs, 6))}
  end

  defp ip_text(<<a, b, c, d>>), do: "#{a}.#{b}.#{c}.#{d}"
  defp ip_text(bin), do: inspect(bin)

  defp rdn_cn({:rdnSequence, rdns}) do
    Enum.find_value(List.flatten(rdns), "", fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, {_, v}} -> to_string(v)
      {:AttributeTypeAndValue, {2, 5, 4, 3}, v} when is_binary(v) or is_list(v) -> to_string(v)
      _ -> nil
    end)
  end

  defp asn1_time({:utcTime, t}), do: parse_time("20" <> to_string(t))
  defp asn1_time({:generalTime, t}), do: parse_time(to_string(t))

  defp parse_time(<<y::binary-4, mo::binary-2, d::binary-2, h::binary-2, mi::binary-2, s::binary-2, "Z">>) do
    {:ok, dt} = NaiveDateTime.new(String.to_integer(y), String.to_integer(mo), String.to_integer(d), String.to_integer(h), String.to_integer(mi), String.to_integer(s))
    NaiveDateTime.diff(dt, ~N[1970-01-01 00:00:00])
  end

  @doc """
  The certificate for `host`: `{certfile, keyfile}` of the kept one whose
  names match (exactly, or by `*.domain`), the newest first; or nil.
  """
  def lookup(host) do
    host = String.downcase(host || "")

    list()
    |> Enum.filter(fn c -> Enum.any?(c.hosts, &matches?(&1, host)) end)
    |> Enum.sort_by(& &1.not_after, :desc)
    |> case do
      [c | _] -> {Path.join(dir(), c.name <> ".crt"), Path.join(dir(), c.name <> ".key")}
      [] -> nil
    end
  end

  defp matches?("*." <> domain, host), do: String.ends_with?(host, "." <> domain) and length(String.split(host, ".")) == length(String.split(domain, ".")) + 1
  defp matches?(name, host), do: String.downcase(name) == host

  def remove(name) do
    files = for ext <- ~w(.crt .key .acme), p = Path.join(dir(), name <> ext), File.exists?(p), do: p
    if files == [], do: {:error, "#{name}: no such certificate"}, else: (Enum.each(files, &File.rm/1); :ok)
  end

  @doc "Keep a certificate (chain) and key made elsewhere."
  def import(name, cert_path, key_path) do
    with {:ok, pem} <- File.read(cert_path),
         {:ok, _der} <- read_cert(cert_path),
         {:ok, key} <- read_key(key_path) do
      File.mkdir_p!(dir())
      File.write!(Path.join(dir(), name <> ".crt"), pem)
      File.write!(Path.join(dir(), name <> ".key"), key_pem_any(key, key_path))
      File.chmod!(Path.join(dir(), name <> ".key"), 0o600)
      :ok
    end
  end

  # An RSA (or other) key is kept as it came.
  defp key_pem_any({:ECPrivateKey, _, _, _, _, _} = key, _path), do: key_pem(key)
  defp key_pem_any(_key, path), do: File.read!(path)

  # -- the local CA ---------------------------------------------------------------------------------

  @doc "The local CA (`{cert_der, key}`), made the first time."
  def ca do
    cert = ca_cert_path()
    keyfile = Path.join(ca_dir(), "ca.key")

    with {:ok, der} <- read_cert(cert), {:ok, key} <- read_key(keyfile) do
      {der, key}
    else
      _ ->
        key = generate_key()
        der = certificate(key, "Lepton local CA (#{Lepton.Sys.hostname()})", [], nil, ca: true)
        File.mkdir_p!(ca_dir())
        File.write!(cert, cert_pem(der))
        File.write!(keyfile, key_pem(key))
        File.chmod!(keyfile, 0o600)
        trust_local_ca()
        {der, key}
    end
  end

  @doc "A certificate for `hosts` from the local CA, kept as `name` (the first host)."
  def local(hosts, name \\ nil) do
    {ca_der, ca_key} = ca()
    key = generate_key()
    der = certificate(key, hd(hosts), hosts, {ca_der, ca_key})
    name = name || file_name(hd(hosts))
    save(name, cert_pem(der) <> cert_pem(ca_der), key)
    {:ok, name}
  end

  @doc "A self-signed certificate for `hosts`."
  def self_signed(hosts, name \\ nil) do
    key = generate_key()
    der = certificate(key, hd(hosts), hosts, nil)
    name = name || file_name(hd(hosts))
    save(name, cert_pem(der), key)
    {:ok, name}
  end

  defp file_name(host), do: host |> String.replace("*", "_wildcard") |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")

  @doc """
  Trust the local CA: Lepton's tools (curl, git, ...: `extra_cacerts/0`),
  and Firefox (its policies file, when it's installed).
  """
  def trust_local_ca do
    firefox = Path.join(Lepton.Apps.dir("firefox"), "usr/lib/firefox")

    if File.dir?(firefox) and File.exists?(ca_cert_path()) do
      dist = Path.join(firefox, "distribution")
      File.mkdir_p!(dist)
      policy = %{"policies" => %{"Certificates" => %{"Install" => [ca_cert_path()]}}}
      File.write!(Path.join(dist, "policies.json"), JSON.encode!(policy))
    end

    :ok
  end

  @doc "The local CA's certificate, for Lepton's own TLS clients to trust (DER list)."
  def extra_cacerts do
    case read_cert(ca_cert_path()) do
      {:ok, der} -> [der]
      _ -> []
    end
  end

  # -- Let's Encrypt (ACME) ---------------------------------------------------------------------------

  @letsencrypt "https://acme-v02.api.letsencrypt.org/directory"
  @staging "https://acme-staging-v02.api.letsencrypt.org/directory"

  def acme_directory(:production), do: @letsencrypt
  def acme_directory(:staging), do: @staging

  @doc """
  A certificate for `domains` from an ACME CA (Let's Encrypt by default):
  the HTTP-01 challenge is answered from `challenge_dir/0`, which httpd
  serves at `/.well-known/acme-challenge/` on port 80. Options:
  `:email`, `:directory` (URL), `:log` (a fun for progress). Returns
  `{:ok, name}` or `{:error, msg}`.
  """
  def acme(domains, opts \\ []) do
    log = opts[:log] || fn _ -> :ok end
    dir_url = opts[:directory] || @letsencrypt

    try do
      acme!(domains, dir_url, opts[:email], log, opts)
    catch
      {:acme, msg} -> {:error, msg}
    end
  end

  defp acme!(domains, dir_url, email, log, opts) do
    s = %{account: account_key(), nonce: nil, kid: nil, http: opts[:http] || [], dir: nil}
    {:ok, dir} = get_json(s, dir_url)
    s = %{s | dir: dir}
    s = new_nonce(s)

    {s, resp} = post(s, dir["newAccount"], Map.merge(%{"termsOfServiceAgreed" => true}, if(email, do: %{"contact" => ["mailto:" <> email]}, else: %{})), :jwk)
    s = %{s | kid: header(resp, "location")}
    log.("account: #{s.kid}")

    {s, order_resp} = post(s, dir["newOrder"], %{"identifiers" => Enum.map(domains, &%{"type" => "dns", "value" => &1})})
    order_url = header(order_resp, "location")
    order = body(order_resp)

    s =
      Enum.reduce(order["authorizations"], s, fn authz_url, s ->
        {s, a} = post(s, authz_url, nil)
        authz = body(a)

        if authz["status"] == "valid" do
          s
        else
          ch = Enum.find(authz["challenges"], &(&1["type"] == "http-01")) || throw({:acme, "no http-01 challenge for #{authz["identifier"]["value"]}"})
          token = ch["token"]
          File.mkdir_p!(challenge_dir())
          File.write!(Path.join(challenge_dir(), token), token <> "." <> thumbprint(s.account))
          log.("answering the challenge for #{authz["identifier"]["value"]}")
          {s, _} = post(s, ch["url"], %{})
          {s, _} = poll(s, authz_url, ["valid"], ["invalid"], "#{authz["identifier"]["value"]} was not validated")
          File.rm(Path.join(challenge_dir(), token))
          s
        end
      end)

    key = generate_key()
    {s, _} = post(s, order["finalize"], %{"csr" => b64(csr(key, domains))})
    {s, done} = poll(s, order_url, ["valid"], ["invalid"], "the order failed")
    {_s, cert} = post(s, body(done)["certificate"], nil)
    name = file_name(hd(domains))
    save(name, cert_body(cert), key, %{"domains" => domains, "email" => email, "directory" => dir_url})
    log.("certificate saved as #{name}")
    {:ok, name}
  end

  @doc "Renew the ACME certificates that expire within `days` days. Returns `[{name, result}]`."
  def renew(days \\ 30, opts \\ []) do
    now = System.os_time(:second)

    for meta_path <- Path.wildcard(Path.join(dir(), "*.acme")),
        name = Path.basename(meta_path, ".acme"),
        {:ok, der} <- [read_cert(Path.join(dir(), name <> ".crt"))],
        info(der).not_after - now < days * 86_400 do
      meta = JSON.decode!(File.read!(meta_path))
      {name, acme(meta["domains"], Keyword.merge([email: meta["email"], directory: meta["directory"]], opts))}
    end
  end

  defp account_key do
    path = Path.join([dir(), "acme", "account.key"])

    case read_key(path) do
      {:ok, k} -> k
      _ ->
        k = generate_key()
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, key_pem(k))
        File.chmod!(path, 0o600)
        k
    end
  end

  defp jwk(key) do
    <<4, x::binary-32, y::binary-32>> = point(key)
    %{"crv" => "P-256", "kty" => "EC", "x" => b64(x), "y" => b64(y)}
  end

  # RFC 7638: the SHA-256 of the JWK's required members, in order.
  def thumbprint(key) do
    j = jwk(key)
    b64(:crypto.hash(:sha256, ~s({"crv":"#{j["crv"]}","kty":"EC","x":"#{j["x"]}","y":"#{j["y"]}"})))
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp jws(s, url, payload, how) do
    protected = %{"alg" => "ES256", "nonce" => s.nonce, "url" => url}
    protected = if how == :jwk, do: Map.put(protected, "jwk", jwk(s.account)), else: Map.put(protected, "kid", s.kid)
    p = b64(JSON.encode!(protected))
    body = if payload == nil, do: "", else: b64(JSON.encode!(payload))
    sig = :public_key.sign(p <> "." <> body, :sha256, s.account)
    JSON.encode!(%{"protected" => p, "payload" => body, "signature" => b64(raw_signature(sig))})
  end

  # ECDSA's DER signature as JWS wants it: r and s, 32 bytes each.
  defp raw_signature(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    <<r::256, s::256>>
  end

  defp request(s, method, url, body \\ nil) do
    :inets.start()
    :ssl.start()
    ssl = if url =~ ~r{^https://(127\.0\.0\.1|localhost)}, do: [verify: :verify_none], else: Lepton.Git.Remote.ssl_opts([])
    req = if body, do: {String.to_charlist(url), [], ~c"application/jose+json", body}, else: {String.to_charlist(url), []}

    case :httpc.request(method, req, [ssl: ssl, timeout: 30_000] ++ s.http, [body_format: :binary], Lepton.Proxy.httpc_profile(url)) do
      {:ok, {{_, code, _}, headers, resp}} -> {code, Map.new(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end), resp}
      {:error, e} -> throw({:acme, "#{url}: #{inspect(e)}"})
    end
  end

  defp get_json(s, url) do
    case request(s, :get, url) do
      {200, _, body} -> {:ok, JSON.decode!(body)}
      {code, _, body} -> throw({:acme, "#{url}: HTTP #{code} #{body}"})
    end
  end

  defp new_nonce(s) do
    {_, h, _} = request(s, :head, s.dir["newNonce"])
    %{s | nonce: h["replay-nonce"]}
  end

  defp post(s, url, payload, how \\ :kid) do
    {code, h, body} = request(s, :post, url, jws(s, url, payload, how))
    s = %{s | nonce: h["replay-nonce"] || s.nonce}

    cond do
      code in 200..299 -> {s, {h, body}}
      code == 400 and body =~ "badNonce" -> post(new_nonce(s), url, payload, how)
      true -> throw({:acme, "#{url}: HTTP #{code}: #{problem(body)}"})
    end
  end

  defp problem(body) do
    case JSON.decode(body) do
      {:ok, %{"detail" => d}} -> d
      _ -> body
    end
  end

  defp poll(s, url, ok, bad, msg, tries \\ 30) do
    {s, resp} = post(s, url, nil)
    status = body(resp)["status"]

    cond do
      status in ok -> {s, resp}
      status in bad -> throw({:acme, "#{msg}: #{inspect(body(resp)["error"] || body(resp))}"})
      tries == 0 -> throw({:acme, "#{msg}: still #{status}"})
      true -> Process.sleep(1000); poll(s, url, ok, bad, msg, tries - 1)
    end
  end

  defp header({h, _}, name), do: h[name]
  defp body({_, b}), do: JSON.decode!(b)
  defp cert_body({_, b}), do: b
end

defmodule Lepton.Certs.DER do
  @moduledoc false
  # Just enough DER (X.690) to write certificates and requests.
  import Bitwise

  def tlv(tag, content) do
    content = IO.iodata_to_binary(content)
    <<tag>> <> len(byte_size(content)) <> content
  end

  defp len(n) when n < 128, do: <<n>>

  defp len(n) do
    bytes = :binary.encode_unsigned(n)
    <<0x80 ||| byte_size(bytes)>> <> bytes
  end

  def seq(items), do: tlv(0x30, items)
  def set(items), do: tlv(0x31, Enum.sort(Enum.map(items, &IO.iodata_to_binary/1)))
  def bool(true), do: tlv(0x01, <<0xFF>>)
  def octet(bin), do: tlv(0x04, bin)
  def utf8(s), do: tlv(0x0C, s)
  def bitstring(bin), do: tlv(0x03, <<0>> <> bin)
  def explicit(n, inner), do: tlv(0xA0 + n, inner)
  def context(n, inner), do: tlv(0xA0 + n, inner)
  def implicit(n, bin), do: tlv(0x80 + n, bin)

  def int(n) when n >= 0 do
    bytes = :binary.encode_unsigned(n)
    bytes = if (:binary.first(bytes) &&& 0x80) != 0, do: <<0>> <> bytes, else: bytes
    tlv(0x02, bytes)
  end

  def oid(text) do
    [a, b | rest] = text |> String.split(".") |> Enum.map(&String.to_integer/1)
    tlv(0x06, [40 * a + b | Enum.map(rest, &base128/1)] |> Enum.map(&if(is_integer(&1), do: <<&1>>, else: &1)))
  end

  defp base128(n) when n < 128, do: <<n>>

  defp base128(n) do
    digits = Integer.digits(n, 128)
    {init, [last]} = Enum.split(digits, -1)
    for(d <- init, into: <<>>, do: <<0x80 ||| d>>) <> <<last>>
  end

  # UTCTime before 2050, GeneralizedTime after.
  def time(unix) do
    {{y, mo, d}, {h, mi, s}} = :calendar.gregorian_seconds_to_datetime(unix + 62_167_219_200)
    p = &String.pad_leading(to_string(&1), 2, "0")
    rest = "#{p.(mo)}#{p.(d)}#{p.(h)}#{p.(mi)}#{p.(s)}Z"
    if y < 2050, do: tlv(0x17, p.(rem(y, 100)) <> rest), else: tlv(0x18, "#{y}" <> rest)
  end
end
