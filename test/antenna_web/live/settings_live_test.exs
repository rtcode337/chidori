defmodule AntennaWeb.SettingsLiveTest do
  use AntennaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AntennaWeb.SettingsLive

  # Chiezo が返す相手の一覧。**相手ごとにモデルと考える量が違う**ことが要点で、
  # だから選択肢を連動させる必要がある。
  @backends [
    %{
      "id" => "claude",
      "label" => "Claude Code CLI",
      "models" => ["sonnet", "opus", "haiku"],
      "efforts" => ["low", "medium", "high"]
    },
    %{"id" => "codex", "label" => "Codex CLI", "models" => [], "efforts" => []}
  ]

  defp stub_backends do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Antenna.HttpStub.stub(fn _request ->
      Antenna.HttpStub.ok(Jason.encode!(%{"backends" => @backends}))
    end)
  end

  describe "モデルと考える量の選択肢" do
    test "空の「相手の既定」を先頭に置く", _ do
      # 指定しないのが普通の使い方なので、探さずに選べるところに置く
      options = SettingsLive.candidate_options(@backends, "claude", "models", "")

      assert [{"相手の既定", ""} | rest] = options
      assert rest == [{"sonnet", "sonnet"}, {"opus", "opus"}, {"haiku", "haiku"}]
    end

    test "相手が持たない項目では「相手の既定」だけになる", _ do
      assert SettingsLive.candidate_options(@backends, "codex", "efforts", "") ==
               [{"相手の既定", ""}]
    end

    test "相手が未指定なら一覧の先頭の候補を出す", _ do
      # 「Chiezo の既定にまかせる」で実際に当たるのが先頭の相手だから
      options = SettingsLive.candidate_options(@backends, "", "models", "")

      assert {"sonnet", "sonnet"} in options
    end

    test "いま入っている値は候補に無くても残す", _ do
      # 落とすと、保存し直した瞬間に既定へ倒れて指定が消える
      options = SettingsLive.candidate_options(@backends, "claude", "models", "消えたモデル")

      assert {"消えたモデル", "消えたモデル"} in options
    end

    test "候補にある値を二重に並べない", _ do
      options = SettingsLive.candidate_options(@backends, "claude", "models", "opus")

      assert Enum.count(options, &(&1 == {"opus", "opus"})) == 1
    end
  end

  describe "設定の画面" do
    test "モデルと考える量がセレクトで出る", %{conn: conn} do
      stub_backends()
      {:ok, live, _html} = live(conn, ~p"/settings")

      html = live |> element("article.topic:first-of-type button", "設定を変える") |> render_click()

      assert html =~ ~s(name="topic[collect_model]")
      assert html =~ ~s(name="topic[collect_effort]")

      # 自由入力ではない（綴りを間違えても保存でき、走らせるまで気づけなかった）
      refute html =~ ~s(<input name="topic[collect_model]" type="text")
      refute html =~ ~s(<input name="topic[collect_effort]" type="text")
    end

    test "相手を選び直すと候補が入れ替わる", %{conn: conn} do
      stub_backends()
      {:ok, live, _html} = live(conn, ~p"/settings")
      live |> element("article.topic:first-of-type button", "設定を変える") |> render_click()

      # **セレクトの中だけを見る。** 相手ごとの一覧（backend_hint）にも同じモデル名が
      # 並ぶので、画面全体で当てると相手を替えても当たり続ける
      models = fn -> live |> element(~s|select[name="topic[collect_model]"]|) |> render() end

      live |> form(".topic-form", topic: %{collect_backend: "claude"}) |> render_change()
      assert models.() =~ "sonnet"

      live |> form(".topic-form", topic: %{collect_backend: "codex"}) |> render_change()

      # codex はモデルも考える量も持たないので、選べるのは既定だけになる
      refute models.() =~ "sonnet"
    end

    test "選び直しても保存はしない", %{conn: conn} do
      # ここで持ち回るのは書きかけの入力だけ。書き込むのは保存を押したとき
      stub_backends()
      {:ok, live, _html} = live(conn, ~p"/settings")
      live |> element("article.topic:first-of-type button", "設定を変える") |> render_click()

      live
      |> form(".topic-form", topic: %{collect_backend: "claude", collect_model: "opus"})
      |> render_change()

      assert Enum.all?(Antenna.Topics.list(), &(&1.collect_model in [nil, ""]))
    end
  end
end
