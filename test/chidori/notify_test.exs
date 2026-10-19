defmodule Chidori.NotifyTest do
  @moduledoc """
  知らせるところ。見ているのは、届けた時刻が残ることと、
  **届かなかったものを知らせた扱いにしないこと**。
  """

  use Chidori.DataCase, async: false

  alias Chidori.HttpStub
  alias Chidori.News
  alias Chidori.Notify
  alias Chidori.Notify.Destination
  alias Chidori.Notify.Settings

  @collection "chidori_tech"
  @digest %{
    title: "まとめ: 基盤の入れ替えが続いた（2026-09-15 01:00）",
    summary: """
    ## 要旨
    この期間は基盤の入れ替えが続きました。

    ## 新しい版
    新しい版が出ました。**移行の要点**はここです。
    出典: https://example.com/1
    """,
    tags: ["まとめ"],
    url: nil,
    image: nil,
    collected_at: nil,
    importance: :normal,
    reason: nil
  }

  setup do
    System.put_env("NTFY_BASE_URL", "http://ntfy.test")
    on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)
    Settings.put(@collection, %{"notify" => "true"})
    Destination.put(%{"topic" => "chidori-tech"})
    :ok
  end

  defp stub_ok do
    test_pid = self()

    HttpStub.stub(fn %{method: :post, url: url, body: body} ->
      send(test_pid, {:notified, url, Jason.decode!(body)})
      HttpStub.ok("{}")
    end)
  end

  test "まとめを知らせる" do
    stub_ok()

    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, url, sent}, 2_000
    assert url == "http://ntfy.test/"
    assert sent["topic"] == "chidori-tech"
    # どの話題のまとめか分かるように、話題の名前を頭に付けて送る
    assert sent["title"] == Notify.notice_title(@collection, @digest.title)
    assert sent["title"] =~ "技術ニュース"
  end

  test "出典の URL は、そのまま本文に残す" do
    # ntfy が URL を見つけて自分でリンクにする。見出しに差し替えると、
    # **行き先が読めないただの文字**になる（画面のほうは逆で、見出しにする）
    stub_ok()
    Notify.deliver(@collection, @digest)

    assert_receive {:notified, _url, sent}, 2_000
    assert sent["message"] =~ "https://example.com/1"
  end

  test "続きを読む先を添える" do
    # 通知の 1 行だけでは足りない
    # 開くのは端末の通知と同じ画面（いちばん新しいまとめを全画面で）
    assert Notify.click_url(@collection, "https://chidori.example.com") ==
             "https://chidori.example.com/news?view=chidori_tech&digest=latest"
  end

  test "手元しか指せないときは、開く先を添えない" do
    # 通知を開くのはたいてい別の機械。電話で押しても localhost は自分自身を指すので、
    # 開けないリンクが付くだけになる（添えなければ、本文をそのまま扱える）
    stub_ok()
    Notify.deliver(@collection, @digest)

    assert_receive {:notified, _url, sent}, 2_000
    refute Map.has_key?(sent, "click")
  end

  test "届かなかったものは、知らせた扱いにしない" do
    # 時刻を進めると、画面に「知らせた」と出て届いていないことに気づけない
    HttpStub.stub(fn %{method: :post} -> {:ok, %{status: 500, body: ""}} end)

    assert Notify.deliver(@collection, @digest) == {:error, {:ntfy_status, 500}}
    refute Notify.last_sent_at(@collection)
  end

  test "宛先が未設定なら、その理由を返す" do
    # 無言で何もしないと、設定を間違えているのかまとめがまだ無いのかが分からない
    Destination.put(%{"topic" => ""})

    assert Notify.deliver(@collection, @digest) == {:error, :no_destination}
  end

  test "知らせない設定の話題は送らない" do
    # 宛先は全部の通知で 1 つなので、話題ごとの「知らせる」で止める
    Settings.put(@collection, %{"notify" => "false"})

    assert Notify.deliver(@collection, @digest) == {:error, :notify_off}
  end

  test "場所を書かなければ、公式の公開サーバーへ送る" do
    # 宛先だけ書いた人のところに何も飛ばず、その理由が画面の隅にしか出ないほうが困る
    System.delete_env("NTFY_BASE_URL")
    stub_ok()

    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, url, _sent}, 2_000
    assert url == Chidori.Ntfy.public_base_url() <> "/"
  end

  test "宛先が空なら、そもそも送らない" do
    # **既定の宛先は持たない** —— 公開の ntfy では誰でも読めるところへ流れる
    Destination.put(%{"topic" => ""})
    HttpStub.stub(fn request -> flunk("送らないはず: #{inspect(request.url)}") end)

    assert Notify.deliver(@collection, @digest) == {:error, :no_destination}
  end

  test "同じまとめでも、押されれば送る" do
    # 押すのは意思表示。そこで黙られると「壊れているのか、もう送ったのか」が
    # 分からない（送ったことは画面に出るので、二度目が要るかは押す人が決める）
    stub_ok()
    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, _url, _sent}, 2_000

    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, _url, _sent}, 2_000
  end

  test "最後に知らせた時刻が残る" do
    # 押した結果が画面に出ないと、届いたのかどうかを確かめようがない
    stub_ok()
    refute Notify.last_sent_at(@collection)

    Notify.deliver(@collection, @digest)
    assert_receive {:notified, _url, _sent}, 2_000
    assert first = Notify.last_sent_at(@collection)

    # 二度目も時刻が進む（押した結果が画面に出る）
    Notify.deliver(@collection, @digest)
    assert_receive {:notified, _url, _sent}, 2_000
    assert DateTime.compare(Notify.last_sent_at(@collection), first) != :lt
  end

  test "まとめが無ければ何もしない" do
    assert Notify.deliver_latest(@collection, %{digests: []}) == {:ok, :nothing_to_send}
  end

  describe "登録した端末へ（Web Push）" do
    @endpoint "https://fcm.googleapis.com/send/device-1"

    defp register_device do
      {ua_public, _ua_private} = :crypto.generate_key(:ecdh, :prime256v1)

      {:ok, _subscription} =
        Chidori.WebPush.Subscriptions.subscribe(%{
          "endpoint" => @endpoint,
          "keys" => %{
            "p256dh" => Chidori.WebPush.b64(ua_public),
            "auth" => Chidori.WebPush.b64(:crypto.strong_rand_bytes(16))
          }
        })
    end

    # ntfy と端末のそれぞれに、決めた状態で答える
    defp stub_channels(ntfy_status, push_status) do
      parent = self()

      HttpStub.stub(fn
        %{url: "http://ntfy.test/", body: body} ->
          send(parent, {:ntfy, Jason.decode!(body)})
          {:ok, %{status: ntfy_status, body: "{}"}}

        %{url: @endpoint, opts: opts} ->
          send(parent, {:push, opts})
          {:ok, %{status: push_status, body: ""}}
      end)
    end

    test "端末だけでも知らせる（ntfy の宛先は要らない）" do
      Destination.put(%{"topic" => ""})
      register_device()
      stub_channels(200, 201)

      assert Notify.ready(@collection) == {:ok, [:push]}
      assert Notify.deliver(@collection, @digest) == {:ok, :sent}
      assert_receive {:push, _opts}
      refute_receive {:ntfy, _sent}
      assert Notify.last_sent_at(@collection)
    end

    test "ntfy と端末の両方へ送る" do
      register_device()
      stub_channels(200, 201)

      assert Notify.ready(@collection) == {:ok, [:ntfy, :push]}
      assert Notify.deliver(@collection, @digest) == {:ok, :sent}
      assert_receive {:ntfy, _sent}
      assert_receive {:push, _opts}
    end

    test "知らせない設定の話題は、端末へも送らない" do
      # 話題ごとの「知らせる」は ntfy と端末の両方に効く
      Settings.put(@collection, %{"notify" => "false"})
      register_device()
      HttpStub.stub(fn request -> flunk("送らないはず: #{inspect(request.url)}") end)

      assert Notify.deliver(@collection, @digest) == {:error, :notify_off}
    end

    test "どちらか 1 つ届けば、知らせた扱いにする" do
      # ntfy が落ちていても端末には届いている。「知らせていない」と出すと、
      # 届いた知らせと画面が食い違う
      register_device()
      stub_channels(500, 201)

      assert Notify.deliver(@collection, @digest) == {:ok, :sent}
      assert Notify.last_sent_at(@collection)
    end

    test "全部届かなければ、知らせた扱いにしない" do
      register_device()
      stub_channels(500, 500)

      assert Notify.deliver(@collection, @digest) == {:error, {:ntfy_status, 500}}
      refute Notify.last_sent_at(@collection)
    end

    test "受け取れなくなった端末は消し、届かなかったことにする" do
      Destination.put(%{"topic" => ""})
      register_device()
      stub_channels(200, 410)

      assert Notify.deliver(@collection, @digest) == {:error, :push_expired}
      assert Chidori.WebPush.Subscriptions.list() == []
      refute Notify.last_sent_at(@collection)

      # 消したあとは宛先が無い
      assert Notify.deliver(@collection, @digest) == {:error, :no_destination}
    end

    test "押すと開くのは、その話題のいちばん新しいまとめ" do
      assert Notify.open_path(@collection) == "/news?view=chidori_tech&digest=latest"
    end

    test "端末の通知には要旨だけを短く載せる（出典の URL は載せない）" do
      # 通知からは URL を押せず、中身の大きさにも上限がある
      body = Notify.push_body(@digest)

      assert body =~ "この期間は基盤の入れ替えが続きました。"
      refute body =~ "https://"

      assert String.length(Notify.push_body(%{@digest | summary: String.duplicate("あ", 500)})) <=
               180
    end
  end

  describe "通知に流す文" do
    test "流すのは要旨と出典だけ" do
      # レポート本文をそのまま送ると、見出しも表も箇条書きも記号のまま並ぶ。
      # 要旨は通知に流す前提で別に書かせてあるので、そこだけを送る
      text = News.digest_text(@digest)

      assert text =~ "この期間は基盤の入れ替えが続きました。"
      refute text =~ "移行の要点"
      refute text =~ "**"

      # 出典は添える（ntfy が URL を見つけて自分でリンクにする）
      assert text =~ "https://example.com/1"

      # 見出しは写さない（ntfy はタイトルを別に持つので、二度並ぶ）
      refute text =~ @digest.title
    end

    test "要点ごとの出典は、その要点のすぐ下に並べる" do
      # レポート全体の出典を最後にまとめて並べると、どの URL がどの要点の根拠
      # なのかが通知から読めない
      digest = %{
        @digest
        | summary: """
          ## 要旨
          この期間は基盤の入れ替えが続きました。

          ・データベースの新版が出ました
          出典: [新版の告知](https://example.com/db)
          ・移行の手引きが公開されました
          出典: [移行の手引き](https://example.com/guide)
          出典: [手引きの解説](https://example.com/guide-2)

          ## 移行の要点
          本文。
          出典: [別の記事](https://example.com/other)
          """
      }

      text = News.digest_text(digest)

      assert text =~
               "・データベースの新版が出ました\n→ https://example.com/db\n" <>
                 "・移行の手引きが公開されました\n→ https://example.com/guide\n" <>
                 "→ https://example.com/guide-2"

      # 要旨に無い章の出典は並べない（どの要点の根拠でもない）
      refute text =~ "https://example.com/other"
      refute text =~ "**"
    end

    test "要旨の無い古いまとめも、飾りを落として流す" do
      # 溜まったまとめは書き換わらない。要旨を書かせる前のものが空で飛ぶより、
      # 本文を飾りなしで流すほうがまだ読める
      old = %{@digest | summary: "React の新版\n新しい版が出ました。\n出典: https://example.com/1"}

      text = News.digest_text(old)

      assert text =~ "新しい版が出ました。"
      assert text =~ "https://example.com/1"
    end
  end

  describe "画面で頼んだ AI の答えが返ったときの知らせ" do
    test "話題の「知らせる」を切っていても、ntfy の宛先へ送る" do
      # 頼んだ本人に「終わった」と返すもので、まとめの知らせとは別
      Settings.put("chidori_movies", %{"notify" => "false"})
      stub_ok()

      assert Notify.deliver_notice("映画館を探し終えました", "本文", "/news?view=chidori_movies", "ask-x") ==
               :ok

      assert_receive {:notified, "http://ntfy.test/", sent}, 2_000
      assert sent["title"] == "映画館を探し終えました"
      assert sent["topic"] == "chidori-tech"
    end

    test "宛先が無ければ送らない" do
      Destination.put(%{"topic" => ""})

      assert Notify.deliver_notice("t", "b", "/news", "ask-x") == {:error, :no_destination}
    end

    test "映画館を探した答えは、出発地・時間・館の数と近い順の名前を書く" do
      result =
        {:ok,
         %{
           origin: "東京駅",
           minutes: 30,
           theaters: for(n <- 1..4, do: %{name: "館#{n}"})
         }}

      assert {"映画館を探し終えました", text} = ChidoriWeb.ShowtimeAsk.notice(:theater_search, result)
      assert text == "東京駅から30分以内に 4 館（館1・館2・館3 ほか）"

      assert {"映画館を探せませんでした", _text} =
               ChidoriWeb.ShowtimeAsk.notice(:theater_search, {:error, :chiezo_unavailable})
    end

    test "上映スケジュールは、上映の見つかった館の数を書く" do
      result =
        {:ok,
         %{
           title: "作品",
           date: "2026-10-20",
           theaters: [%{name: "館1", found: true}, %{name: "館2", found: false}]
         }}

      assert {_title, "作品（2026-10-20）: 2 館のうち 1 館で上映が見つかりました"} =
               ChidoriWeb.ShowtimeAsk.notice(:showtimes, result)
    end
  end

  test "通知の見出しに、どの話題のまとめかを付ける" do
    assert Notify.notice_title("chidori_tech", "まとめ: 新しい版が出た（2026-10-10 07:00 JST）") ==
             "技術ニュースのまとめ: 新しい版が出た（2026-10-10 07:00 JST）"

    assert Notify.notice_title("chidori_tech", "週の振り返り") == "技術ニュース｜週の振り返り"
    # 話題の定義に無い収集は、見出しのまま
    assert Notify.notice_title("unknown_x", "まとめ: X") == "まとめ: X"
  end
end
