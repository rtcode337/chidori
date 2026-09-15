defmodule Tazuna.NtfyTest do
  use ExUnit.Case, async: false

  alias Tazuna.Ntfy

  test "宛先は収集ごとに決められる" do
    # 同じところへまとめて流すと、技術の話を追いたいだけの人に暮らしの話まで届く
    assert Ntfy.env_name("tazuna_tech") == "TAZUNA_TECH_NTFY_TOPIC"
    assert Ntfy.env_name("tazuna_news") == "TAZUNA_NEWS_NTFY_TOPIC"
  end

  test "未設定なら宛先は無い" do
    # **既定の宛先を勝手に決めない** —— 推測できる名前ほど、公開の ntfy では危ない
    System.delete_env("TAZUNA_TECH_NTFY_TOPIC")

    assert Ntfy.topic_for("tazuna_tech") == nil
  end

  test "設定していないときは、どこへ書けばよいかを理由に載せる" do
    System.delete_env("TAZUNA_TECH_NTFY_TOPIC")
    System.put_env("NTFY_BASE_URL", "http://ntfy.test")
    on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)

    assert Ntfy.ready("tazuna_tech") == {:error, {:ntfy_topic_missing, "TAZUNA_TECH_NTFY_TOPIC"}}
  end

  test "ルート URL の末尾のスラッシュは畳む" do
    System.put_env("NTFY_BASE_URL", "http://ntfy.test/")
    on_exit(fn -> System.delete_env("NTFY_BASE_URL") end)

    assert Ntfy.base_url() == "http://ntfy.test"
  end
end
