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
    summary: "この期間は基盤の入れ替えが続きました。\n\n新しい版が出ました。\n出典: https://example.com/1",
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
    stub_ok()
    Notify.deliver(@collection, @digest)

    assert_receive {:notified, _url, sent}, 2_000
    assert sent["click"] =~ "/news?view=tazuna_tech"
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

  test "場所が未設定なら、そもそも送らない" do
    # **既定の宛先を勝手に決めない** —— 公開の ntfy では誰でも読めるところへ流れる
    System.delete_env("NTFY_BASE_URL")

    assert Notify.deliver(@collection, @digest) == {:error, :ntfy_base_url_missing}
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
    test "見出しと本文を、飾りなしで並べる" do
      # Markdown として描かれない場所なので、`**` を置くと記号がそのまま出る
      text = News.digest_text(@digest)

      assert text =~ @digest.title
      assert text =~ "https://example.com/1"
      refute text =~ "**"
    end

    test "1 行目は、まとめの最初の段落" do
      # 通知は畳まれて先頭しか見えないことがある
      assert News.digest_lead(@digest) == "この期間は基盤の入れ替えが続きました。"
    end
  end
end
