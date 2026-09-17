defmodule Tazuna.NtfyTest do
  use Tazuna.DataCase, async: false

  alias Tazuna.Notify.Settings
  alias Tazuna.Ntfy

  test "宛先は収集ごとに決められる" do
    # 同じところへまとめて流すと、技術の話を追いたいだけの人に暮らしの話まで届く
    Settings.put("tazuna_tech", %{"ntfy_topic" => "tech"})
    Settings.put("tazuna_news", %{"ntfy_topic" => "living"})

    assert Ntfy.topic_for("tazuna_tech") == "tech"
    assert Ntfy.topic_for("tazuna_news") == "living"
  end

  test "書いていなければ宛先は無い" do
    # **既定の宛先を勝手に決めない** —— 推測できる名前ほど、公開の ntfy では危ない
    assert Ntfy.topic_for("tazuna_tech") == nil
  end

  test "空にすれば、知らせなくなる" do
    Settings.put("tazuna_tech", %{"ntfy_topic" => "tech"})
    Settings.put("tazuna_tech", %{"ntfy_topic" => ""})

    assert Ntfy.topic_for("tazuna_tech") == nil
  end

  test "場所は画面で書いたほうが勝つ" do
    # 既定は環境の事情なので環境変数から取るが、話題ごとに別のサーバーへも流せる
    System.put_env("NTFY_BASE_URL", "http://default.test")
    on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)

    assert Ntfy.base_url("tazuna_tech") == "http://default.test"

    Settings.put("tazuna_tech", %{"ntfy_base_url" => "http://written.test/"})
    # 末尾のスラッシュは畳む
    assert Ntfy.base_url("tazuna_tech") == "http://written.test"
  end

  test "押せない理由を、押す前に返す" do
    # **決まっていないのは宛先だけ。** 場所は書かなければ公式の公開サーバーへ倒れる
    System.delete_env("NTFY_BASE_URL")
    assert Ntfy.ready("tazuna_tech") == {:error, :ntfy_topic_missing}
    assert Ntfy.base_url("tazuna_tech") == Ntfy.public_base_url()

    System.put_env("NTFY_BASE_URL", "http://ntfy.test")
    on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)
    assert Ntfy.ready("tazuna_tech") == {:error, :ntfy_topic_missing}

    Settings.put("tazuna_tech", %{"ntfy_topic" => "tech"})
    assert Ntfy.ready("tazuna_tech") == {:ok, {"http://ntfy.test", "tech"}}
  end

  test "http で始まらない場所は断る" do
    # 押せる形だけを受け取る（保存してから届かないのが分かるのでは遅い）
    assert {:error, changeset} = Settings.put("tazuna_tech", %{"ntfy_base_url" => "ntfy.test"})
    assert "http:// か https:// で書いてください" in errors_on(changeset).ntfy_base_url
  end
end
