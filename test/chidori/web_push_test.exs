defmodule Chidori.WebPushTest do
  @moduledoc """
  端末へ知らせる口（Web Push）。見ているのは、**配信先が読める形で暗号にしていること**
  （RFC 8291 の aes128gcm。Apple の配信先はこれしか受け取らない）と、**署名が鍵で確かめられ、
  名乗りに連絡先を書いていないこと**（RFC 8292 の VAPID）、届かなくなった端末を消すこと。
  """

  use Chidori.DataCase, async: false

  alias Chidori.HttpStub
  alias Chidori.WebPush
  alias Chidori.WebPush.Key
  alias Chidori.WebPush.Subscriptions

  # 受け取る側（ブラウザ）が中身を開く手順。RFC 8291 のとおりに組み直す
  defp decrypt(body, ua_public, ua_private, auth) do
    <<salt::binary-size(16), rs::unsigned-big-32, idlen::unsigned-8, rest::binary>> = body
    <<as_public::binary-size(idlen), sealed::binary>> = rest

    hmac = &:crypto.mac(:hmac, :sha256, &1, &2)
    ecdh = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    ikm = hmac.(hmac.(auth, ecdh), "WebPush: info" <> <<0>> <> ua_public <> as_public <> <<1>>)
    prk = hmac.(salt, ikm)
    <<cek::binary-size(16), _::binary>> = hmac.(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-size(12), _::binary>> = hmac.(prk, "Content-Encoding: nonce" <> <<0, 1>>)

    size = byte_size(sealed) - 16
    <<ciphertext::binary-size(size), tag::binary-size(16)>> = sealed

    plain = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, "", tag, false)
    %{rs: rs, idlen: idlen, as_public: as_public, plain: plain}
  end

  defp ua_keys do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    {ua_public, ua_private, :crypto.strong_rand_bytes(16)}
  end

  defp subscribe(endpoint \\ "https://push.example.com/send/abc") do
    {ua_public, ua_private, auth} = ua_keys()

    {:ok, subscription} =
      Subscriptions.subscribe(
        %{
          "endpoint" => endpoint,
          "keys" => %{"p256dh" => WebPush.b64(ua_public), "auth" => WebPush.b64(auth)}
        },
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
      )

    {subscription, ua_public, ua_private, auth}
  end

  describe "暗号（RFC 8291）" do
    test "受け取る側の鍵で開くと、元の中身に戻る" do
      {ua_public, ua_private, auth} = ua_keys()
      payload = ~s({"title":"まとめ","body":"本文","url":"/news?view=chidori_tech&digest=latest"})

      body = WebPush.encrypt(payload, ua_public, auth)
      opened = decrypt(body, ua_public, ua_private, auth)

      # 1 記録だけで送り切る。末尾の 0x02 は「最後の記録」の印
      assert opened.plain == payload <> <<2>>
      assert opened.rs == 4096
      assert opened.idlen == 65
      assert <<4, _::binary-size(64)>> = opened.as_public
    end

    test "送るたびに一時鍵と salt を作り直す" do
      # 同じ鍵で 2 度暗号にすると、中身の手掛かりを渡すことになる
      {ua_public, _ua_private, auth} = ua_keys()

      <<salt1::binary-size(16), _::binary-size(5), key1::binary-size(65), _::binary>> =
        WebPush.encrypt("a", ua_public, auth)

      <<salt2::binary-size(16), _::binary-size(5), key2::binary-size(65), _::binary>> =
        WebPush.encrypt("a", ua_public, auth)

      refute salt1 == salt2
      refute key1 == key2
    end

    test "RFC 8291 の例と同じ本文になる" do
      # 付録 A の値。一時鍵と salt を例に揃えれば、本文は 1 バイトも違わないはず
      d = fn text ->
        {:ok, bin} = WebPush.decode_b64(text)
        bin
      end

      as_public =
        d.(
          "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
        )

      as_private = d.("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")

      ua_public =
        d.(
          "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        )

      auth = d.("BTBZMqHH6r4Tts7J_aSIgg")
      salt = d.("DGv6ra1nlYgDCS1FRnbzlw")

      body =
        WebPush.encrypt("When I grow up, I want to be a watermelon", ua_public, auth,
          as_keypair: {as_public, as_private},
          salt: salt
        )

      assert WebPush.b64(body) ==
               "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
    end
  end

  describe "署名（VAPID）" do
    test "送り手の公開鍵で確かめられ、宛先・期限・名乗りが入っている" do
      key = Key.get()
      now = 1_800_000_000
      jwt = WebPush.vapid_jwt("https://web.push.apple.com/QGuQyavXutnMH...", key, now)

      [header, claims, signature] = String.split(jwt, ".")
      {:ok, header_json} = WebPush.decode_b64(header)
      {:ok, claims_json} = WebPush.decode_b64(claims)
      {:ok, <<r::unsigned-big-256, s::unsigned-big-256>> = raw} = WebPush.decode_b64(signature)

      assert byte_size(raw) == 64
      assert Jason.decode!(header_json) == %{"typ" => "JWT", "alg" => "ES256"}

      der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

      assert :crypto.verify(:ecdsa, :sha256, header <> "." <> claims, der, [
               key.public_key,
               :prime256v1
             ])

      decoded = Jason.decode!(claims_json)
      assert decoded["aud"] == "https://web.push.apple.com"
      assert decoded["exp"] == now + 12 * 60 * 60
      assert decoded["sub"] == ChidoriWeb.Endpoint.url()

      # **連絡先のメールアドレスは書かない**（配信先のログに残る）
      refute claims_json =~ "@"
      refute claims_json =~ "mailto"
    end

    test "宛先は scheme と host だけ（標準でない port は残す）" do
      assert WebPush.audience("https://fcm.googleapis.com/fcm/send/abc") ==
               "https://fcm.googleapis.com"

      assert WebPush.audience("https://push.example.com:8443/x") ==
               "https://push.example.com:8443"
    end

    test "送り手の鍵は 1 つだけ作り、作り直さない" do
      # 鍵が替わると、登録済みの端末はすべて受け取れなくなる
      first = WebPush.public_key()
      assert WebPush.public_key() == first
      assert {:ok, <<4, _::binary-size(64)>>} = WebPush.decode_b64(first)
      assert Repo.aggregate(Key, :count) == 1
    end
  end

  describe "送る" do
    test "aes128gcm と VAPID の見出しを付けて、配信先へ送る" do
      {subscription, ua_public, ua_private, auth} = subscribe()
      parent = self()

      HttpStub.stub(fn %{method: :post, url: url, body: body, opts: opts} ->
        send(parent, {:pushed, url, body, opts})
        {:ok, %{status: 201, body: ""}}
      end)

      results = Subscriptions.deliver_all("見出し", "本文", "/news?view=x&digest=latest")
      assert [{%{id: id}, :ok}] = results
      assert id == subscription.id

      assert_receive {:pushed, url, body, opts}
      assert url == "https://push.example.com/send/abc"
      assert opts[:content_type] == "application/octet-stream"

      headers = Map.new(opts[:headers])
      assert headers["content-encoding"] == "aes128gcm"
      assert headers["ttl"] =~ ~r/\A\d+\z/
      assert "vapid t=" <> _ = headers["authorization"]
      assert headers["authorization"] =~ ", k=" <> WebPush.public_key()

      %{plain: plain} = decrypt(body, ua_public, ua_private, auth)
      sent = plain |> binary_part(0, byte_size(plain) - 1) |> Jason.decode!()
      assert sent["title"] == "見出し"
      assert sent["body"] == "本文"
      assert sent["url"] == "/news?view=x&digest=latest"
    end

    test "受け取れなくなった端末（410・404）は消す" do
      # 残すと送るたびに失敗が並び、本当に届いていない端末と見分けが付かない
      subscribe("https://push.example.com/send/gone")
      subscribe("https://push.example.com/send/missing")
      subscribe("https://push.example.com/send/alive")

      HttpStub.stub(fn %{url: url} ->
        cond do
          url =~ "gone" -> {:ok, %{status: 410, body: ""}}
          url =~ "missing" -> {:ok, %{status: 404, body: ""}}
          true -> {:ok, %{status: 201, body: ""}}
        end
      end)

      results = Subscriptions.deliver_all("見出し", "本文", "/")
      assert Enum.count(results, &(elem(&1, 1) == :expired)) == 2

      assert [%{endpoint: "https://push.example.com/send/alive"}] = Subscriptions.list()
      assert Subscriptions.result_text(results) =~ "1 台に送りました"
      assert Subscriptions.result_text(results) =~ "2 台の登録を外しました"
    end

    test "届かなかった端末は、配信元が返した理由まで出す" do
      subscribe("https://push.example.com/send/refused")

      HttpStub.stub(fn _request ->
        {:ok, %{status: 403, body: ~s({"reason":"BadJwtToken"})}}
      end)

      text = "見出し" |> Subscriptions.deliver_all("本文", "/") |> Subscriptions.result_text()

      assert text =~ "1 台は送れませんでした"
      assert text =~ "403"
      assert text =~ "BadJwtToken"
    end

    test "ほかの失敗では消さない" do
      # 配信先の一時的な不調で、端末の登録まで失わない
      subscribe()
      HttpStub.stub(fn _request -> {:ok, %{status: 500, body: "oops"}} end)

      assert [{_s, {:error, {:push_status, 500, "oops"}}}] =
               Subscriptions.deliver_all("見出し", "本文", "/")

      assert [_still_there] = Subscriptions.list()
    end
  end

  describe "端末の登録" do
    test "同じ宛先は上書きする（2 台に数えない）" do
      {first, _p, _k, _a} = subscribe()
      {second, _p, _k, _a} = subscribe()

      assert first.id == second.id
      assert [_one] = Subscriptions.list()
    end

    test "鍵の形が違う登録・https でない宛先は受け取らない" do
      assert {:error, _changeset} =
               Subscriptions.subscribe(%{
                 "endpoint" => "https://push.example.com/x",
                 "keys" => %{"p256dh" => "short", "auth" => "short"}
               })

      {ua_public, _ua_private, auth} = ua_keys()

      assert {:error, _changeset} =
               Subscriptions.subscribe(%{
                 "endpoint" => "http://push.example.com/x",
                 "keys" => %{"p256dh" => WebPush.b64(ua_public), "auth" => WebPush.b64(auth)}
               })
    end

    test "端末の名前はブラウザの名乗りから作る" do
      assert Subscriptions.label(
               "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
             ) == "iPhone"

      assert Subscriptions.label(
               "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
             ) == "Mac Chrome"

      assert Subscriptions.label("") == "端末"
    end
  end

  test "送り手の名乗りは、https で手元の名前でないときだけ通るものとみなす" do
    assert Chidori.WebPush.subject_ok?("https://chidori.example.com")
    refute Chidori.WebPush.subject_ok?("http://chidori.example.com:7000")
    refute Chidori.WebPush.subject_ok?("https://localhost")
  end

  describe "配信元に繋がらないとき" do
    test "1 度だけ送り直す（閉じられた接続を使い回して落ちることがある）" do
      subscribe("https://push.example.com/send/retry")
      me = self()

      HttpStub.stub(fn _request ->
        send(me, :tried)

        if Process.get(:tried_once),
          do: {:ok, %{status: 201, body: ""}},
          else:
            (
              Process.put(:tried_once, true)
              {:error, :socket_closed_remotely}
            )
      end)

      assert [{_subscription, :ok}] = Subscriptions.deliver_all("見出し", "本文", "/")
      assert_received :tried
      assert_received :tried
    end

    test "送り直しても繋がらなければ、理由を添えて返す" do
      subscribe("https://push.example.com/send/down")
      HttpStub.stub(fn _request -> {:error, :timeout} end)

      results = Subscriptions.deliver_all("見出し", "本文", "/")
      assert [{_subscription, {:error, {:push_unavailable, :timeout}}}] = results
      assert Subscriptions.result_text(results) =~ "配信元に繋がりませんでした（:timeout）"
    end
  end
end
