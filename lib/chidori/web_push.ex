defmodule Chidori.WebPush do
  @moduledoc """
  端末へ知らせる口（Web Push）。ホーム画面に入れた Chidori（iPhone を含む）や、
  通知を許したブラウザへ、まとめの知らせを届けます。ntfy と並べて使えます
  （`Chidori.Notify`）。

  **暗号と署名はここで組みます**（RFC 8291 の aes128gcm と RFC 8292 の VAPID）。
  出来合いの部品は古い書き方（aesgcm）で送るものが多く、**Apple の配信先は
  aes128gcm しか受け取りません**。どちらも `:crypto` だけで組める大きさです。

  - 送り手の鍵（VAPID）は最初に要ったときに作って DB に置きます（`Chidori.WebPush.Key`）。
    手で用意させず、イメージにも焼き込みません
  - 宛先の端末は `Chidori.WebPush.Subscriptions` が持ちます
  - 送るのは `Chidori.Http` 越し（テストはスタブへ差し替わる）

  **送り先はブラウザの配信元だけです**（`allowed_endpoint?/1`）。宛先はブラウザが
  渡してくるものをそのまま受け取るので、ここで絞らないと、画面から登録させた任意の
  URL（LAN の中の機器を含む）へ Chidori が POST を投げる口になります。

  **届けられなくなった端末（404・410）は消します。** アプリを消した・通知を切った
  端末で、配信先がもう受け取らないと答えたものです。残すと送るたびに失敗が並び、
  本当に届いていない端末と見分けが付きません。
  """

  alias Chidori.Http
  alias Chidori.WebPush.Key

  # 1 つの記録に収める大きさ（暗号文の器）。中身は 1 記録で送り切る
  @record_size 4096
  # 配信先が端末に渡せないあいだ持っていてよい時間（秒）。まとめは翌日には古い
  @ttl 86_400
  # 署名の有効期限（RFC 8292 は 24 時間以内を求める）
  @jwt_lifetime 12 * 60 * 60

  # 送ってよい配信元。名前の一致か、`.` を挟んだ後ろの一致だけを見る
  # （`evilpush.apple.com.example` や `xpush.apple.com` を通さない）。
  # Safari は web.push.apple.com、Chrome・Edge（Android 含む）は fcm.googleapis.com、
  # Firefox は updates.push.services.mozilla.com、旧 Edge・Windows は *.notify.windows.com
  @push_hosts ["fcm.googleapis.com", "updates.push.services.mozilla.com"]
  @push_host_suffixes [".push.apple.com", ".push.services.mozilla.com", ".notify.windows.com"]

  @timeout 10_000
  @connect_timeout 5_000

  @doc """
  ブラウザに渡す送り手の公開鍵（`applicationServerKey`）。base64url・65 バイトの非圧縮形。
  """
  def public_key, do: Key.get().public_key |> b64()

  @doc """
  1 台の端末へ送ります。`subscription` は `endpoint`・`p256dh`・`auth`（base64url）を持つもの。

  返すのは `:ok`、届けられなくなった端末なら `:expired`、それ以外は `{:error, 理由}`。
  **配信元でない宛先には送りません**（`{:error, :endpoint_not_allowed}`。前に登録された
  ものが残っていても、送る手前で止める）。
  """
  def send_notification(subscription, payload, opts \\ []) when is_binary(payload) do
    key = Keyword.get_lazy(opts, :key, &Key.get/0)

    with true <- allowed_endpoint?(subscription.endpoint) || :not_allowed,
         {:ok, ua_public} <- decode_key(subscription.p256dh, 65),
         {:ok, auth} <- decode_key(subscription.auth, 16) do
      body = encrypt(payload, ua_public, auth)
      jwt = vapid_jwt(subscription.endpoint, key)

      headers = [
        {"authorization", "vapid t=#{jwt}, k=#{b64(key.public_key)}"},
        {"content-encoding", "aes128gcm"},
        {"ttl", Integer.to_string(@ttl)},
        {"urgency", "normal"}
      ]

      case post_once_more(subscription.endpoint, body, headers) do
        {:ok, %{status: status}} when status in [200, 201, 202] -> :ok
        {:ok, %{status: status}} when status in [404, 410] -> :expired
        {:ok, %{status: status, body: body}} -> {:error, {:push_status, status, short(body)}}
        {:error, reason} -> {:error, {:push_unavailable, reason}}
      end
    else
      :not_allowed -> {:error, :endpoint_not_allowed}
      :error -> {:error, :bad_subscription}
    end
  end

  @doc """
  ブラウザの配信元の宛先か。https・既定のポート・利用者名なしで、名前が配信元の
  ものに当たるときだけ `true`。
  """
  def allowed_endpoint?(endpoint) when is_binary(endpoint) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: "https", host: host, port: 443, userinfo: nil}}
      when is_binary(host) and host != "" ->
        host = String.downcase(host)
        host in @push_hosts or Enum.any?(@push_host_suffixes, &String.ends_with?(host, &1))

      _other ->
        false
    end
  end

  def allowed_endpoint?(_endpoint), do: false

  @doc """
  RFC 8291 の形で中身を暗号にします（1 記録だけの aes128gcm）。

  返すのは本文そのもの: `salt(16) || rs(4) || idlen(1) || 送り手の一時鍵(65) || 暗号文+タグ`。
  一時鍵と salt は**送るたびに作り直します**（同じ鍵で 2 度暗号にしない）。
  """
  def encrypt(payload, ua_public, auth_secret, opts \\ []) do
    {as_public, as_private} =
      Keyword.get_lazy(opts, :as_keypair, fn -> :crypto.generate_key(:ecdh, :prime256v1) end)

    salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

    ecdh_secret = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
    prk_key = hmac(auth_secret, ecdh_secret)
    key_info = "WebPush: info" <> <<0>> <> ua_public <> as_public
    ikm = hmac(prk_key, key_info <> <<1>>)

    prk = hmac(salt, ikm)
    <<cek::binary-size(16), _::binary>> = hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-size(12), _::binary>> = hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>)

    # 末尾の 0x02 は「これが最後の記録」の印
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, payload <> <<2>>, "", true)

    salt <>
      <<@record_size::unsigned-big-32, byte_size(as_public)::unsigned-8>> <>
      as_public <> ciphertext <> tag
  end

  # **繋がらなかったら 1 度だけ送り直す。** OTP の HTTP は配信元への接続を使い回すので、
  # 前に送ってから時間が空くと、向こうが閉じた接続に送って `socket_closed_remotely` で
  # 落ちることがある（張り直せば届く）。中身は同じものを送ってよい
  defp post_once_more(endpoint, body, headers, tries \\ 2) do
    case Http.post(endpoint, body,
           headers: headers,
           content_type: "application/octet-stream",
           timeout: @timeout,
           connect_timeout: @connect_timeout
         ) do
      {:error, _reason} when tries > 1 -> post_once_more(endpoint, body, headers, tries - 1)
      result -> result
    end
  end

  @doc """
  VAPID の署名（ES256 の JWT）。`aud` は配信先の scheme://host、`sub` は Chidori の URL。

  **`sub` に連絡先のメールアドレスは書きません。** RFC 8292 は https の URL でもよいとしていて、
  ここに書いたものは配信先のログに残ります。
  """
  def vapid_jwt(endpoint, key, now \\ System.system_time(:second)) do
    header = b64(Jason.encode!(%{typ: "JWT", alg: "ES256"}))

    claims =
      b64(Jason.encode!(%{aud: audience(endpoint), exp: now + @jwt_lifetime, sub: subject()}))

    signing_input = header <> "." <> claims
    der = :crypto.sign(:ecdsa, :sha256, signing_input, [key.private_key, :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)

    signing_input <> "." <> b64(<<r::unsigned-big-256, s::unsigned-big-256>>)
  end

  @doc "配信先の scheme://host（標準でない port は付ける）。"
  def audience(endpoint) do
    uri = URI.parse(endpoint)
    URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port})
  end

  @doc "送り手を名乗る URL（Chidori の URL）。"
  def subject, do: ChidoriWeb.Endpoint.url()

  @doc """
  送り手の名乗りが通るものか。**https で、手元の名前（localhost）でないこと** ——
  Apple の配信元は http の URL を名乗ると 403（`BadJwtToken`）で断る。
  """
  def subject_ok?(subject \\ subject()) do
    case URI.parse(subject) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        host not in ["localhost", "127.0.0.1", "::1"]

      _other ->
        false
    end
  end

  @doc "base64url（詰め物なし）。"
  def b64(binary), do: Base.url_encode64(binary, padding: false)

  @doc "base64url を読みます。詰め物の有無はどちらでも受け取ります（ブラウザで違う）。"
  def decode_b64(text) when is_binary(text),
    do: text |> String.trim() |> String.trim_trailing("=") |> Base.url_decode64(padding: false)

  def decode_b64(_text), do: :error

  defp decode_key(text, size) do
    case decode_b64(text) do
      {:ok, key} when byte_size(key) == size -> {:ok, key}
      _other -> :error
    end
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp short(body) when is_binary(body), do: binary_part(body, 0, min(byte_size(body), 200))
  defp short(_body), do: ""
end
