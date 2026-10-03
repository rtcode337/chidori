defmodule Tazuna.NotifyTest do
  @moduledoc """
  知らせるところ。見ているのは 2 つ ——
  **同じものを二度知らせないこと**と、**届かなかったものを知らせた扱いにしないこと**。
  """

  use Tazuna.DataCase, async: false

  alias Tazuna.HttpStub
  alias Tazuna.News
  alias Tazuna.Notify
  alias Tazuna.Notify.Settings

  @collection "tazuna_tech"
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
    Settings.put(@collection, %{"ntfy_topic" => "tazuna-tech"})
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
    assert sent["topic"] == "tazuna-tech"
    assert sent["title"] == @digest.title
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
    assert Notify.click_url(@collection, "https://tazuna.example.com") ==
             "https://tazuna.example.com/news?view=tazuna_tech"
  end

  test "手元しか指せないときは、開く先を添えない" do
    # 通知を開くのはたいてい別の機械。電話で押しても localhost は自分自身を指すので、
    # 開けないリンクが付くだけになる（添えなければ、本文をそのまま扱える）
    stub_ok()
    Notify.deliver(@collection, @digest)

    assert_receive {:notified, _url, sent}, 2_000
    refute Map.has_key?(sent, "click")
  end

  test "同じまとめは二度知らせない" do
    # まとめは Chiezo に溜まっていて、読み直すたびに同じものが返る
    stub_ok()

    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, _url, _sent}, 2_000

    assert Notify.deliver(@collection, @digest) == {:ok, :already_sent}
    refute_receive {:notified, _url, _sent}, 300
  end

  test "宛先を変えたら、変えた先へは改めて届く" do
    # 「もう知らせた」と黙られると、新しい宛先には何も来ないまま気づけない
    stub_ok()
    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, _url, _sent}, 2_000

    Settings.put(@collection, %{"ntfy_topic" => "tazuna-tech-2"})
    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, _url, sent}, 2_000
    assert sent["topic"] == "tazuna-tech-2"
  end

  test "届かなかったものは、知らせた扱いにしない" do
    # 記録すると、次に読み直したときに「もう知らせた」と黙って飛ばされ、
    # そのまとめは永遠に届かない
    HttpStub.stub(fn %{method: :post} -> {:ok, %{status: 500, body: ""}} end)

    assert Notify.deliver(@collection, @digest) == {:error, {:ntfy_status, 500}}
    refute Notify.sent?(@collection, @digest.title, "tazuna-tech")
  end

  test "宛先が未設定なら、その理由を返す" do
    # 無言で何もしないと、設定を間違えているのかまとめがまだ無いのかが分からない
    Settings.put(@collection, %{"ntfy_topic" => ""})

    assert Notify.deliver(@collection, @digest) == {:error, :ntfy_topic_missing}
  end

  test "場所を書かなければ、公式の公開サーバーへ送る" do
    # 宛先だけ書いた人のところに何も飛ばず、その理由が画面の隅にしか出ないほうが困る
    System.delete_env("NTFY_BASE_URL")
    stub_ok()

    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, url, _sent}, 2_000
    assert url == Tazuna.Ntfy.public_base_url() <> "/"
  end

  test "宛先が空なら、そもそも送らない" do
    # **既定の宛先は持たない** —— 公開の ntfy では誰でも読めるところへ流れる
    Settings.put(@collection, %{"ntfy_topic" => ""})

    assert Notify.deliver(@collection, @digest) == {:error, :ntfy_topic_missing}
  end

  test "押されたときは、知らせ済みでも送る" do
    # 押すのは意思表示。そこで黙られると「壊れているのか、もう送ったのか」が
    # 分からない（送ったことは画面に出るので、二度目が要るかは押す人が決める）
    stub_ok()
    assert Notify.deliver(@collection, @digest) == {:ok, :sent}
    assert_receive {:notified, _url, _sent}, 2_000

    assert Notify.deliver(@collection, @digest, force: true) == {:ok, :sent}
    assert_receive {:notified, _url, _sent}, 2_000
  end

  test "最後に知らせた時刻が残る" do
    # 押した結果が画面に出ないと、届いたのかどうかを確かめようがない
    stub_ok()
    refute Notify.last_sent_at(@collection)

    Notify.deliver(@collection, @digest)
    assert_receive {:notified, _url, _sent}, 2_000
    assert first = Notify.last_sent_at(@collection)

    # **二度目も時刻が進む。** 行は増えないので、足した時刻で見ていると
    # 押しても画面が動かない
    Notify.deliver(@collection, @digest, force: true)
    assert_receive {:notified, _url, _sent}, 2_000
    assert DateTime.compare(Notify.last_sent_at(@collection), first) != :lt
  end

  test "まとめが無ければ何もしない" do
    assert Notify.deliver_latest(@collection, %{digests: []}) == {:ok, :nothing_to_send}
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
end
