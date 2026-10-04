defmodule Tazuna.NtfyTest do
  use Tazuna.DataCase, async: false

  alias Tazuna.Notify.Destination
  alias Tazuna.Notify.Settings
  alias Tazuna.Ntfy

  test "宛先は全部の通知で 1 つ、知らせるかどうかは話題ごと" do
    # 話題ごとに宛先を持たせていた頃は、同じトピックを画面ごとに書き写していた
    Destination.put(%{"topic" => "shared"})
    Settings.put("tazuna_tech", %{"notify" => "true"})

    assert Ntfy.topic() == "shared"
    assert {:ok, {_base, "shared"}} = Ntfy.ready("tazuna_tech")
    assert Ntfy.ready("tazuna_news") == {:error, :notify_off}
  end

  test "書いていなければ宛先は無い" do
    # **既定の宛先を勝手に決めない** —— 推測できる名前ほど、公開の ntfy では危ない
    assert Ntfy.topic() == nil
  end

  test "空にすれば、どの話題も知らせなくなる" do
    Destination.put(%{"topic" => "shared"})
    Destination.put(%{"topic" => ""})
    Settings.put("tazuna_tech", %{"notify" => "true"})

    assert Ntfy.topic() == nil
    assert Ntfy.ready("tazuna_tech") == {:error, :ntfy_topic_missing}
  end

  test "場所は画面で書いたほうが勝つ" do
    # 既定は環境の事情なので環境変数から取る
    System.put_env("NTFY_BASE_URL", "http://default.test")
    on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)

    assert Ntfy.base_url() == "http://default.test"

    Destination.put(%{"base_url" => "http://written.test/"})
    # 末尾のスラッシュは畳む
    assert Ntfy.base_url() == "http://written.test"
  end

  test "押せない理由を、押す前に返す" do
    # **決まっていないのは宛先だけ。** 場所は書かなければ公式の公開サーバーへ倒れる
    System.delete_env("NTFY_BASE_URL")
    Settings.put("tazuna_tech", %{"notify" => "true"})
    assert Ntfy.ready("tazuna_tech") == {:error, :ntfy_topic_missing}
    assert Ntfy.base_url() == Ntfy.public_base_url()

    System.put_env("NTFY_BASE_URL", "http://ntfy.test")
    on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)

    Destination.put(%{"topic" => "tech"})
    assert Ntfy.ready("tazuna_tech") == {:ok, {"http://ntfy.test", "tech"}}
  end

  test "http で始まらない場所は断る" do
    # 押せる形だけを受け取る（保存してから届かないのが分かるのでは遅い）
    assert {:error, changeset} = Destination.put(%{"base_url" => "ntfy.test"})
    assert "http:// か https:// で書いてください" in errors_on(changeset).base_url
  end
end
