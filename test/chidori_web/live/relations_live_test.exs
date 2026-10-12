defmodule ChidoriWeb.RelationsLiveTest do
  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ChidoriWeb.RelationsLive

  test "最初に開くのは画家の図", %{conn: conn} do
    # 関連図のタブの先頭（`Relations.views/0` の並び）
    {:ok, _live, html} = live(conn, ~p"/relations")

    assert html =~ "画家の影響と時代"
  end

  test "芸能人の関連図を表示する", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations?view=people")

    assert html =~ "芸能人のつながり"

    # **表示例の図は描かない。** 本物と見分けが付かないので、読み込みが終わるまで
    # 手書きの関連図が出て「これは何」になる（実際にそう言われた）
    assert html =~ "まだ読み込んでいません"
    refute html =~ "松田優作"
  end

  test "画家の関連図へ切り替えられる", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/relations?view=people")

    html = live |> element(~s|a[href="/relations?view=painters"]|) |> render_click()

    assert html =~ "画家の影響と時代"

    # **誰が出るかは Chiezo 次第**なので、名前では見ない（前のテストが読み込んだ図が
    # 残っていると落ちる）。切り替わったことは、見出しと図の器で分かる
    assert html =~ "relation-canvas"
    assert html =~ "様式の色" or html =~ "この図の見方"
  end

  test "知らない種類は画家の図に丸める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations?view=%2E%2E%2F")

    assert html =~ "画家の影響と時代"
  end

  test "開くたびに Chiezo へ聞きに行かない", %{conn: conn} do
    # 8,000 人ぶんを読むので数秒かかるのに、Chiezo の側は数時間に 1 度しか動かない。
    # 開いた回数だけ待たされる意味が無い
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    restart_relations()
    test_pid = self()

    Chidori.HttpStub.stub(fn
      %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
        Chidori.HttpStub.ok(~s({"backends":[]}))

      %{url: url} ->
        send(test_pid, {:asked, url})
        Chidori.HttpStub.ok(~s({"results":[],"total":0}))
    end)

    {:ok, _live, _html} = live(conn, ~p"/relations?view=painters")
    assert_receive {:asked, _url}, 2_000
    assert wait_until(fn -> Chidori.Relations.current("painters").checked_at != nil end)

    # 2 回目に開いても聞きに行かない
    flush()
    {:ok, live, html} = live(conn, ~p"/relations?view=painters")
    refute_receive {:asked, _url}, 300
    assert html =~ "最新の情報を取得"

    # 押したときだけ取りに行く
    live |> element("button", "最新の情報を取得") |> render_click()
    assert_receive {:asked, _url}, 2_000
  end

  defp flush do
    receive do
      _message -> flush()
    after
      0 -> :ok
    end
  end

  describe "押した合図" do
    test "開いたときの読み直し中は、押せるまま", %{conn: conn} do
      # **読むだけなので止める理由が無い。** 一緒くたに :loading で止めていた頃は、
      # 開くたびに数秒ボタンが押せず、しかも「送っています」と嘘が出ていた
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      # 開いたときに読みに行くのは、まだ 1 度も読めていないときだけ。
      # 前のテストが読んでいると、このテストの合図が来ない
      restart_relations()
      test_pid = self()

      Chidori.HttpStub.stub(fn
        # **止めるのは図を読むところだけ。** 相手の一覧は別に引いているので、
        # そちらまで止めると、解放し忘れが次のテストへ持ち越す
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Chidori.HttpStub.ok(~s({"backends":[]}))

        # 設定欄を開いたときに読む収集の設定も止めない（止めるのは図の読み直しだけ）
        %{url: "http://chiezo.test:7010/v1/collect" <> _rest} ->
          Chidori.HttpStub.ok(~s({"collections":[]}))

        _request ->
          # 応答を止めたまま、止めている自分を教える（終わらせるのはテスト側）
          send(test_pid, {:asked, self()})

          receive do
            :go -> Chidori.HttpStub.ok(~s({"results":[],"total":0}))
          after
            5_000 -> {:error, :timeout}
          end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)

      assert_receive {:asked, worker}, 2_000

      # 読み直しの最中でも、ボタンは押せるまま（ボタンそのものを見る —— ページ全体で
      # 探すと、関係ない要素の disabled まで拾う）
      button = live |> element("form[phx-submit=collect] button") |> render()
      assert button =~ "収集の設定を更新"
      refute button =~ "disabled"

      # 止めたままにすると、次のテストへ :loading のまま持ち越す。
      # 1 回の読み直しで何度か聞きに行くので、続きも残らず解放する
      send(worker, :go)

      assert wait_until(fn ->
               receive do
                 {:asked, pid} -> send(pid, :go)
               after
                 0 -> :ok
               end

               Chidori.Relations.current("painters").status != :loading
             end)
    end

    test "Chiezo が取り込み中でも押せる（知らせるだけ）", %{conn: conn} do
      # **ボタンが集めさせていた頃の名残で止めていた。** いまは送るだけなので、
      # 取り込みが走っていても困らない。走っていることは知らせる —— 図がもうすぐ
      # 変わるので、いま読んでいるものが最新でないと分かる
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      restart_relations()

      Chidori.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ingest/status"} ->
          Chidori.HttpStub.ok(~s({"state":"running","running":true,"source":"chidori_painters"}))

        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Chidori.HttpStub.ok(~s({"results":[],"total":0}))
          else
            Chidori.HttpStub.ok(~s({"collections":[]}))
          end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)

      assert wait_until(fn -> render(live) =~ "いま Chiezo が取り込み中です" end)
      refute live |> element("form[phx-submit=collect] button") |> render() =~ "disabled"
    end

    test "いま何をしているのかを出す", %{conn: conn} do
      # 押してから設定が届くまでに何往復かある。「収集中…」だけだと、
      # 押せていないのと区別が付かない
      restart_relations()
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      Chidori.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ingest/status"} ->
          Chidori.HttpStub.ok(~s({"running":false}))

        %{method: :post, url: "http://chiezo.test:7010/v1/collect"} ->
          send(test_pid, {:asked, self()})

          receive do
            :go -> Chidori.HttpStub.ok("{}")
          after
            5_000 -> {:error, :timeout}
          end

        %{method: :post} ->
          Chidori.HttpStub.ok("{}")

        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Chidori.HttpStub.ok(~s({"results":[],"total":0}))
          else
            Chidori.HttpStub.ok(~s({"collections":[]}))
          end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "収集の設定を更新" end)

      # ボタンは「送る設定」と同じ枠に入っているので、フォームごと送る
      live |> element("form[phx-submit=collect]") |> render_submit(%{})

      assert_receive {:asked, worker}, 2_000
      assert wait_until(fn -> render(live) =~ "Chiezo に収集を依頼しています" end)

      send(worker, :go)

      assert wait_until(fn ->
               receive do
                 {:asked, pid} -> send(pid, :go)
               after
                 0 -> :ok
               end

               Chidori.Relations.current("painters").status != :loading
             end)
    end

    test "押した合図はサーバーの応答を待たずに出す", %{conn: conn} do
      # 集まるものが無い日は往復が一瞬で終わる。状態の変化だけに任せると、
      # 押したのかどうかが画面に残らない
      # 設定欄は Chiezo から読めたときに出るので、Chiezo を向けておく
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

      Chidori.HttpStub.stub(fn %{url: url} ->
        if String.contains?(url, "/v1/ai/backends"),
          do: Chidori.HttpStub.ok(~s({"backends":[]})),
          else: Chidori.HttpStub.ok(~s({"collections":[],"results":[],"total":0}))
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)

      assert render(live) =~ ~s(phx-disable-with="送っています…")
    end
  end

  describe "代表作" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

      docs = [
        %{
          "title" => "クロード・モネ",
          "body" => "説明",
          "tags" => ["画家", "年代:1860-1920", "代表作:印象・日の出"]
        }
      ]

      Chidori.HttpStub.stub(fn
        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Chidori.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => 1}))
          else
            Chidori.HttpStub.ok(Jason.encode!(%{"collections" => []}))
          end
      end)

      # 図の状態は全体で1つなので、直前のテストの読み直しが終わるのを待ってから頼む
      # （走っている間の依頼は捨てられるので、頼んでもすぐには始まらない）
      assert wait_until(fn -> Chidori.Relations.current("painters").status != :loading end)
      Chidori.Relations.refresh("painters")

      # **読み終えたことは、中身で確かめる。** 前のテストから ready のままなので、
      # 状態だけを見るとすぐ抜けて、読み直しが走っている最中に次のテストへ進む
      assert wait_until(fn ->
               relation = Chidori.Relations.current("painters")

               settled?(relation) and
                 Enum.any?(relation.nodes, &(&1.name == "クロード・モネ" and &1[:works] == ["印象・日の出"]))
             end)

      :ok
    end

    test "名前を押すと、図に重ねて出す", %{conn: conn} do
      # 図の下に足すと、押した人が画面の外にいることがある
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      html = live |> element(~s|[phx-value-name="クロード・モネ"]|) |> render_click()

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
    end

    test "閉じられる", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      live |> element(~s|[phx-value-name="クロード・モネ"]|) |> render_click()
      html = live |> element(~s|[phx-click="close_work"]|) |> render_click()

      refute html =~ ~s(role="dialog")
    end

    test "図の外を押しても Esc でも閉じられる", %{conn: conn} do
      # 押した先は同じところ。閉じ方を1つしか用意しないと、行き止まりになる
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      live |> element(~s|[phx-value-name="クロード・モネ"]|) |> render_click()
      assert render(live) =~ ~s(phx-click-away="close_work")
      assert render(live) =~ ~s(phx-key="Escape")

      refute render_keydown(live, "close_work", %{"key" => "Escape"}) =~ ~s(role="dialog")
    end
  end

  describe "画家の姿" do
    # 題名はほかのテストと重ねない（引いた結果は 1 日覚えるため）
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

      docs = [
        %{"title" => "肖像のある画家", "body" => "説明", "tags" => ["画家", "年代:1860-1920"]},
        %{"title" => "肖像の無い画家", "body" => "説明", "tags" => ["画家", "年代:1870-1930"]}
      ]

      Chidori.HttpStub.stub(fn %{url: url} ->
        cond do
          String.contains?(url, "/filter?") ->
            Chidori.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => 2}))

          String.contains?(url, "/v1/jawiki/doc") and
              String.contains?(url, URI.encode_www_form("肖像のある画家")) ->
            Chidori.HttpStub.ok(
              Jason.encode!(%{
                "title" => "肖像のある画家",
                "opening" => "画家。",
                "extra" => %{"image" => "https://example.com/self-portrait.jpg"}
              })
            )

          true ->
            Chidori.HttpStub.ok(Jason.encode!(%{"collections" => []}))
        end
      end)

      assert wait_until(fn -> Chidori.Relations.current("painters").status != :loading end)
      Chidori.Relations.refresh("painters")

      assert wait_until(fn ->
               relation = Chidori.Relations.current("painters")
               settled?(relation) and Enum.any?(relation.nodes, &(&1.name == "肖像のある画家"))
             end)

      :ok
    end

    test "記事に画像があれば、自画像や写真として出す", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      live |> element(~s|[phx-value-name="肖像のある画家"]|) |> render_click()
      html = render_async(live)

      assert html =~ ~s(class="portrait")
      assert html =~ "https://example.com/self-portrait.jpg"
    end

    test "画像が無ければ何も出さない", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      live |> element(~s|[phx-value-name="肖像の無い画家"]|) |> render_click()
      refute render_async(live) =~ ~s(class="portrait")
    end
  end

  describe "絵の見つからない代表作" do
    # **ほかのテストと題名を重ねない。** 引いた結果は 1 日覚えるので、同じ題名を
    # 絵つきで引いたテストが先に走ると、ここでも絵が見つかってしまう
    @work "記事の無い絵（画像検索のテスト）"

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

      docs = [
        %{
          "title" => "画像検索の画家",
          "body" => "説明",
          "tags" => ["画家", "年代:1860-1920", "代表作:" <> @work]
        }
      ]

      Chidori.HttpStub.stub(fn
        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Chidori.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => 1}))
          else
            Chidori.HttpStub.ok(Jason.encode!(%{"collections" => []}))
          end
      end)

      assert wait_until(fn -> Chidori.Relations.current("painters").status != :loading end)
      Chidori.Relations.refresh("painters")

      assert wait_until(fn ->
               relation = Chidori.Relations.current("painters")
               settled?(relation) and Enum.any?(relation.nodes, &(&1.name == "画像検索の画家"))
             end)

      :ok
    end

    test "画像検索へつなぐ", %{conn: conn} do
      # 記事を持たない作品のほうが多い。落とすと、代表作が入っているのに何も見られない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      live |> element(~s|[phx-value-name="画像検索の画家"]|) |> render_click()
      html = render_async(live)

      assert html =~ "Google 画像検索で見る"
      assert html =~ "tbm=isch"
    end
  end

  # **収集の状態は 1 つのプロセスに溜まる。** 押した時刻も覚えているので、
  # 前のテストが押していると次のテストが「少し待ってから」で弾かれる（並びで
  # 結果が変わる）。押すテストは、まっさらな状態から始める
  describe "消えた画家" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      docs = [
        %{"title" => "残っている画家", "body" => "説明", "tags" => ["画家", "年代:1860-1920"]},
        %{
          "title" => "消された画家",
          "body" => "説明",
          "tags" => ["画家", "年代:21世紀", "_chiezo_removed"],
          "extra" => %{"removed_reason" => "区画に入らない", "removed_at" => "2026-09-26T15:19:39+00:00"}
        }
      ]

      Chidori.HttpStub.stub(fn
        %{method: :post, url: url, body: body} ->
          send(test_pid, {:posted, url, Jason.decode!(body)})
          Chidori.HttpStub.ok("{}")

        %{url: "http://chiezo.test:7010/v1/ingest/status"} ->
          Chidori.HttpStub.ok(~s({"running":false}))

        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Chidori.HttpStub.ok(~s({"backends":[]}))

        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Chidori.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => 2}))
          else
            Chidori.HttpStub.ok(Jason.encode!(%{"collections" => []}))
          end
      end)

      assert wait_until(fn -> Chidori.Relations.current("painters").status != :loading end)
      Chidori.Relations.refresh("painters")

      assert wait_until(fn ->
               relation = Chidori.Relations.current("painters")
               settled?(relation) and Enum.any?(relation[:removed] || [], &(&1.name == "消された画家"))
             end)

      :ok
    end

    test "理由つきで並び、名指しで戻すよう頼める", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)

      html = render(live)
      assert html =~ "消えた画家（1）"
      assert html =~ "区画に入らない"

      live
      |> element(~s|form[phx-submit="restore_painter"]|)
      |> render_submit(%{"name" => "消された画家", "note" => ""})

      assert_receive {:posted, url, body}, 2_000
      assert url =~ "/focus"
      assert body["titles"] == ["消された画家"]
      assert body["note"] =~ "_chiezo_restore"
      assert body["note"] =~ "区画に入らない"
    end
  end

  defp restart_relations do
    :ok = Supervisor.terminate_child(Chidori.Supervisor, Chidori.Relations)
    {:ok, _pid} = Supervisor.restart_child(Chidori.Supervisor, Chidori.Relations)
    :ok
  end

  # 設定欄を開いて、Chiezo から読み終えるまで待つ。**設定は開いたときだけ読む**ので、
  # 巡回の欄や「収集の設定を更新」を触るテストは、まずここを通る
  defp open_settings(live) do
    live |> element("#settings-toggle") |> render_click()
    assert wait_until(fn -> has_element?(live, "form#collect-form") end)
    live
  end

  # 読み直しが走っていないか（走っている間は画面が操作を止める）
  defp settled?(relation), do: relation[:step] in [nil, %{}]

  defp wait_until(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_until(check, tries - 1)
    end
  end

  describe "線の座標" do
    alias ChidoriWeb.RelationsLive

    test "エッジごとに両端の座標を返す" do
      relation = %{
        nodes: [
          %{id: "a", x: 10, y: 20},
          %{id: "b", x: 30, y: 60, label_width: 20, label_height: 10}
        ],
        edges: [%{from: "a", to: "b", kind: :influence, label: "光"}]
      }

      assert [line] = RelationsLive.edge_lines(relation, relation.nodes)
      assert {line.x1, line.y1} == {10, 20}
      assert line.label == "光"

      # 線の上に出す札の位置は**中央どうし**で出す（札が片方へ寄らない）
      assert line.mid_x == 20
    end

    test "矢印の先は、相手の札の枠で止める" do
      # 中央まで引くと、先端が札の下に隠れて「どちらへ向かっているのか」が読めない
      relation = %{
        nodes: [
          %{id: "a", x: 0, y: 0},
          %{id: "b", x: 100, y: 0, label_width: 20, label_height: 10}
        ],
        edges: [%{from: "a", to: "b", kind: :influence, label: nil}]
      }

      assert [line] = RelationsLive.edge_lines(relation, relation.nodes)
      # 真横から来るので、左の辺（中央から幅の半分だけ手前）で止まる
      assert {line.x2, line.y2} == {90.0, 0.0}
    end

    test "斜めから来る線は、近いほうの辺で止める" do
      relation = %{
        nodes: [
          %{id: "a", x: 0, y: 0},
          %{id: "b", x: 100, y: 100, label_width: 20, label_height: 10}
        ],
        edges: [%{from: "a", to: "b", kind: :influence, label: nil}]
      }

      assert [line] = RelationsLive.edge_lines(relation, relation.nodes)
      # 45 度なので上の辺のほうが近い（高さの半分 = 5 だけ手前）
      assert {line.x2, line.y2} == {95.0, 95.0}
    end

    test "図に出ていない相手への線は落とす" do
      relation = %{
        nodes: [%{id: "a", x: 0, y: 0}],
        edges: [%{from: "a", to: "居ない", kind: :related, label: nil}]
      }

      assert RelationsLive.edge_lines(relation, relation.nodes) == []
    end

    test "ノードが増えても線ごとに探し直さない" do
      # かつてはエッジごとに全ノードを線形探索していた（500 人で 25,500 回）。
      # 件数を増やしても現実的な時間で返ることだけ押さえる
      nodes = for i <- 1..2_000, do: %{id: "n#{i}", x: i, y: i}
      edges = for i <- 1..1_999, do: %{from: "n#{i}", to: "n#{i + 1}", kind: :related, label: nil}

      {us, lines} =
        :timer.tc(fn -> RelationsLive.edge_lines(%{nodes: nodes, edges: edges}, nodes) end)

      assert length(lines) == 1_999
      assert div(us, 1000) < 500
    end
  end

  describe "描く数を絞る" do
    alias ChidoriWeb.RelationsLive

    defp node(id, x, y, r), do: %{id: id, x: x, y: y, radius: r, kind: :artist}

    defp graph(nodes), do: %{nodes: nodes, edges: []}

    test "見えている範囲の外は描かない" do
      far = node("far", 5_000, 5_000, 30)
      near = node("near", 100, 100, 30)
      viewport = %{x: 0, y: 0, w: 400, h: 400, ppu: 1.0}

      drawn = RelationsLive.drawn_nodes(graph([far, near]), viewport)
      assert Enum.map(drawn, & &1.id) == ["near"]
    end

    test "画面の上で小さすぎるものは描かない" do
      # 全体表示では点にしかならず、DOM を重くするだけで何も伝えない
      big = node("big", 10, 10, 30)
      tiny = node("tiny", 20, 20, 1)
      viewport = %{x: 0, y: 0, w: 400, h: 400, ppu: 1.0}

      drawn = RelationsLive.drawn_nodes(graph([big, tiny]), viewport)
      assert Enum.map(drawn, & &1.id) == ["big"]
    end

    test "夫婦の相手は、小さくても描く" do
      # 線は両端が描かれているときだけ引くので、相手が間引かれると夫婦の線が出なかった
      big = node("big", 10, 10, 30)
      tiny = node("tiny", 200, 200, 1)
      stranger = node("stranger", 300, 300, 1)
      viewport = %{x: 0, y: 0, w: 400, h: 400, ppu: 1.0}

      relation = %{
        graph([big, tiny, stranger])
        | edges: [%{from: "big", to: "tiny", kind: :spouse}]
      }

      drawn = RelationsLive.drawn_nodes(relation, viewport)
      assert Enum.map(drawn, & &1.id) == ["big", "tiny"]
    end

    test "拡大すると小さい丸も出てくる" do
      tiny = node("tiny", 20, 20, 1)
      fit = %{x: 0, y: 0, w: 400, h: 400, ppu: 1.0}
      zoomed = %{x: 0, y: 0, w: 40, h: 40, ppu: 10.0}

      assert RelationsLive.drawn_nodes(graph([tiny]), fit) == []
      assert [%{id: "tiny"}] = RelationsLive.drawn_nodes(graph([tiny]), zoomed)
    end

    test "多すぎるときは大きい順に頭打ちにする" do
      # 図がどれだけ大きくても、描く数が一定に収まる
      nodes = for i <- 1..3_000, do: node("n#{i}", 10, 10, rem(i, 40) + 10)
      viewport = %{x: 0, y: 0, w: 400, h: 400, ppu: 1.0}

      drawn = RelationsLive.drawn_nodes(graph(nodes), viewport)

      assert length(drawn) < length(nodes)
      # 残ったものは大きい順
      radii = Enum.map(drawn, & &1.radius)
      assert radii == Enum.sort(radii, :desc)
    end

    test "範囲がまだ分からなければ、大きいものだけを描く" do
      # 画面が繋がる前の 1 回目。全部並べると、そこでもう固まる
      big = node("big", 10, 10, 30)
      tiny = node("tiny", 20, 20, 1)

      drawn = RelationsLive.drawn_nodes(graph([big, tiny]), nil)
      assert Enum.map(drawn, & &1.id) == ["big"]
    end

    test "描かれていない相手への線は引かない" do
      # 片方しか出ていない線は、どこへ向かうのか読めないまま画面の外へ消える
      a = node("a", 10, 10, 30)
      b = node("b", 20, 20, 30)
      relation = %{nodes: [a, b], edges: [%{from: "a", to: "b", kind: :related, label: nil}]}

      assert RelationsLive.edge_lines(relation, [a]) == []
      assert [_line] = RelationsLive.edge_lines(relation, [a, b])
    end
  end

  describe "巡回ごとに相手を選ぶ" do
    defp painters_collection_json do
      item = %{
        "name" => "chidori_painters",
        "enabled" => true,
        "prompt" => "x",
        "cursor" => "",
        "extract" => %{"source" => "jawiki", "tag" => "画家"},
        "sweeps" => [
          %{
            "name" => "ざっと見る",
            "interval_minutes" => 360,
            "enabled" => true,
            "backend" => "claude"
          },
          %{
            "name" => "整理",
            "interval_minutes" => 1440,
            "enabled" => true,
            "worker" => "精査"
          },
          %{"name" => "割り込み", "on_demand" => true, "enabled" => true}
        ]
      }

      {Jason.encode!(%{"collections" => [item]}), Jason.encode!(item)}
    end

    defp stub_chiezo(test_pid) do
      {collections, one} = painters_collection_json()

      Chidori.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Chidori.HttpStub.ok(
            ~s({"backends":[) <>
              ~s({"id":"codex","label":"Codex","kind":"backend","models":["gpt-a","gpt-b"]},) <>
              ~s({"id":"claude","label":"Claude","kind":"backend","models":["opus"]},) <>
              ~s({"id":"worker:精査","label":"精査","kind":"worker","models":[]}) <>
              ~s(]})
          )

        %{url: "http://chiezo.test:7010/v1/ingest/status"} ->
          Chidori.HttpStub.ok(~s({"running":false}))

        %{method: :patch, body: body} ->
          send(test_pid, {:patched, body})
          Chidori.HttpStub.ok("{}")

        %{method: :post} ->
          Chidori.HttpStub.ok("{}")

        %{url: url} ->
          cond do
            String.contains?(url, "/filter?") -> Chidori.HttpStub.ok(~s({"results":[],"total":0}))
            String.ends_with?(url, "/v1/collect") -> Chidori.HttpStub.ok(collections)
            true -> Chidori.HttpStub.ok(one)
          end
      end)
    end

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      stub_chiezo(self())
      restart_relations()
    end

    test "ワーカーを選ぶと、その値のまま Chiezo へ送られる", %{conn: conn} do
      # 相手の欄に入ったまま送れば、Chiezo が `worker` へ振り分ける ——
      # こちら側が振り分けると、どこに入れるかを知っているのが 2 か所になる
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|ざっと見る|backend" => "worker:精査"})

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      rough = Enum.find(Jason.decode!(body)["sweeps"], &(&1["name"] == "ざっと見る"))

      assert rough["backend"] == "worker:精査"
    end

    test "ワーカーに頼む回は、そのワーカーが選ばれた状態で出る", %{conn: conn} do
      # Chiezo は別の項目（`worker`）で返すので、相手の欄と比べても一致しない ——
      # こちらで相手の欄の値へ直さないと、何も選ばれていないように見える
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      html = live |> element("form#collect-form table") |> render()

      assert html =~ ~s(<option value="worker:精査" selected=)
    end

    test "ワーカーも相手の選択肢に並ぶ", %{conn: conn} do
      # **一覧に無いものは選ばせようがない。** Chiezo は相手とワーカーを同じ一覧で
      # 返すので、こちらは種類で見出しを分けて並べるだけ
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      html = live |> element("form#collect-form table") |> render()

      assert html =~ ~s(<optgroup)
      assert html =~ ~s(<option value="worker:精査")
    end

    test "ワーカーを選ぶと、モデルの欄は出ない", %{conn: conn} do
      # 渡す先はそのときの枠で決まるので、モデルを 1 つ選んでも
      # どの相手に対する指定なのかが決まらない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|ざっと見る|backend" => "worker:精査"})

      html = live |> element("form#collect-form table") |> render()

      refute html =~ ~s(name="sweep|ざっと見る|model")
    end

    test "考える量の欄は持たない", %{conn: conn} do
      # モデルの名前に畳んであるので、残すと選べるのに効かない欄になる
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      html = live |> element("form#collect-form table") |> render()

      refute html =~ "effort"
    end

    test "選んだ相手が、図が届いても元に戻らない", %{conn: conn} do
      # **これが「選んだのに反映されない」の正体だった。** フォームの中身を
      # サーバーが覚えていないと、図や状態が届いた拍子に描き直されて、
      # 選んだところが Chiezo に入っている値へ戻る（選んだつもりで押すと、
      # いま入っている値がそのまま送り返される）
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|ざっと見る|backend" => "codex", "sweep|ざっと見る|model" => "gpt-b"})

      # 図が届いたことにして描き直す（実際には読み直しが終わったとき）
      send(live.pid, {:relation_updated, Chidori.Relations.current("painters")})
      html = live |> element("form#collect-form table") |> render()

      assert html =~ ~s(<option value="codex" selected=)
      assert html =~ ~s(<option value="gpt-b" selected=)
    end

    test "走らない理由は Chiezo が言う" do
      # **予定を持っていないことと、走らないことは違う。** どちらも予定が空なので、
      # 区別せずに出すと「いますぐ」と書いてある回を何日も待ち続けることになる
      rows =
        ChidoriWeb.Collect.sweep_rows(%{
          collection: %{
            enabled: true,
            partitions_total: 10,
            sweeps: [
              %{
                name: "整理",
                backend: nil,
                model: nil,
                effort: nil,
                interval_minutes: 360,
                cover_days: nil,
                on_demand: false,
                use_extract: false,
                use_feed: false,
                enabled: true,
                blocked: "「ざっと見る」の一周待ち",
                next_run_at: nil,
                last_run_at: nil,
                last_status: nil,
                last_error: nil,
                partitions_visited: 0
              }
            ]
          }
        })

      assert [%{next: "「ざっと見る」の一周待ち"}] = rows
    end

    test "時計を持たない巡回にも相手を選べる", %{conn: conn} do
      # 画家のモーダルから頼む「詳しく調べて」は割り込みとして走る。**人が待っている
      # 場面**なので、定時の巡回と同じ相手を使う理由が無い
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "整理" end)

      html = live |> element("form#collect-form table") |> render()
      assert html =~ "時計なし"
      assert html =~ "頼まれたとき"
      assert html =~ ~s(name="sweep|割り込み|backend")
    end

    test "モデルも巡回ごとに選べる", %{conn: conn} do
      # **相手だけ選べても足りない。** 同じ相手でもモデルで結果も時間も変わるので、
      # 巡回ごとに選べないと「じっくりだけ重いモデルで」が表せない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "整理" end)

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|整理|backend" => "codex", "sweep|整理|model" => "gpt-b"})

      # 候補は選び直した相手のもの（別の相手のモデルは並ばない）
      html = live |> element(~s(select[name="sweep|整理|model"])) |> render()
      assert html =~ "gpt-a"
      assert html =~ "gpt-b"
      refute html =~ "opus"

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      sweep = Enum.find(Jason.decode!(body)["sweeps"], &(&1["name"] == "整理"))
      assert sweep["model"] == "gpt-b"
    end

    test "選べるものが無い欄は出さない", %{conn: conn} do
      # **「既定」しか入っていないセレクトは、押せるのに何も選べない。**
      # 考える量を持たない相手と、モデルの名前に考える量が埋まっている相手
      # （Antigravity）がここに当たる —— Chiezo 側が空の一覧で知らせてくる
      Chidori.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Chidori.HttpStub.ok(
            ~s({"backends":[{"id":"antigravity","label":"Antigravity","models":["gemini-3.8-flash-high"],"efforts":[]}]})
          )

        %{url: url} ->
          cond do
            String.contains?(url, "/v1/collect/") ->
              Chidori.HttpStub.ok(elem(painters_collection_json(), 1))

            String.contains?(url, "/v1/collect") ->
              Chidori.HttpStub.ok(elem(painters_collection_json(), 0))

            true ->
              Chidori.HttpStub.ok(~s({"results":[],"total":0}))
          end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|ざっと見る|backend" => "antigravity"})

      html = live |> element("form#collect-form table") |> render()
      assert html =~ ~s(name="sweep|ざっと見る|model")
      refute html =~ ~s(name="sweep|ざっと見る|effort")
    end

    test "選び直した欄が、前に覚えた値に上書きされない", %{conn: conn} do
      # **一度覚えた欄を二度と変えられなくなっていた。** 相手を選んだ拍子に
      # 「モデル: 空」まで覚え、そのあとモデルを選んでも空のまま送られる ——
      # 画面では選べているように見えるので、押すまで気づけない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "割り込み" end)

      # まず相手を選ぶ（このときモデルは空のまま送られてくる）
      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|整理|backend" => "codex", "sweep|整理|model" => ""})

      # 次にモデルを選ぶ
      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|整理|backend" => "codex", "sweep|整理|model" => "gpt-5.6-sol-high"})

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      sweep = Enum.find(Jason.decode!(body)["sweeps"], &(&1["name"] == "整理"))
      assert sweep["model"] == "gpt-5.6-sol-high"
    end

    test "読み直している最中に押しても、設定は送られる", %{conn: conn} do
      # **押下が黙って捨てられていた。** 8,000 件の読み直しは数十秒かかり、そのあいだ
      # ボタンは押せるのに何も起きない —— 画面には何も出ないので、設定が送られて
      # いないことに気づきようがなかった
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      # 溜まったものの読み出しだけを止めて、読み直しが終わらない状態を作る
      {collections, one} = painters_collection_json()
      test_pid = self()

      Chidori.HttpStub.stub(fn
        %{method: :patch, body: body} ->
          send(test_pid, {:patched, body})
          Chidori.HttpStub.ok("{}")

        %{method: :post} ->
          Chidori.HttpStub.ok("{}")

        %{url: url} ->
          cond do
            String.contains?(url, "/filter?") ->
              send(test_pid, {:reading, self()})

              receive do
                :go -> Chidori.HttpStub.ok(~s({"results":[],"total":0}))
              after
                5_000 -> {:error, :timeout}
              end

            String.ends_with?(url, "/v1/collect") ->
              Chidori.HttpStub.ok(collections)

            String.contains?(url, "/v1/ingest/status") ->
              Chidori.HttpStub.ok(~s({"running":false}))

            true ->
              Chidori.HttpStub.ok(one)
          end
      end)

      Chidori.Relations.refresh("painters")
      assert_receive {:reading, reader}, 2_000
      assert Chidori.Relations.current("painters").status == :loading

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|ざっと見る|backend" => "codex"})

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      sweep = Enum.find(Jason.decode!(body)["sweeps"], &(&1["name"] == "ざっと見る"))
      assert sweep["backend"] == "codex"

      # 止めたままにすると、次のテストへ :loading のまま持ち越す
      send(reader, :go)

      assert wait_until(fn ->
               receive do
                 {:reading, pid} -> send(pid, :go)
               after
                 0 -> :ok
               end

               Chidori.Relations.current("painters").status != :loading
             end)
    end

    test "選んだものが Chiezo へ送られる", %{conn: conn} do
      # **空文字も送る。** あれは「Chiezo の既定にまかせる」を選んだという意思表示で、
      # 落とすと一度決めた相手を画面から外せない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      open_settings(live)
      assert wait_until(fn -> render(live) =~ "ざっと見る" end)

      live
      |> element("form#collect-form")
      |> render_change(%{
        "sweep|ざっと見る|backend" => "codex",
        "sweep|ざっと見る|model" => "gpt-b",
        "sweep|整理|backend" => ""
      })

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      sweeps = Jason.decode!(body)["sweeps"]
      rough = Enum.find(sweeps, &(&1["name"] == "ざっと見る"))
      deep = Enum.find(sweeps, &(&1["name"] == "整理"))

      assert rough["backend"] == "codex"
      assert rough["model"] == "gpt-b"
      assert deep["backend"] == ""
    end
  end

  describe "未レビューの区画を先にざっと見てもらう" do
    alias ChidoriWeb.RelationsLive

    test "区画ごとの未レビューの人数を、Chiezo と同じ規則で数える" do
      collection = %{partitions: [%{key: "日本|-", count: 25}, %{key: "フランス|-", count: 20}]}

      nodes = [
        %{name: "あ", tags: ["地域:日本", "年代:1900-1950"], unreviewed?: true},
        %{name: "い", tags: ["地域:日本", "年代:1910-1960"], unreviewed?: true},
        %{name: "う", tags: ["地域:日本", "年代:1920-1970"], unreviewed?: false},
        %{name: "え", tags: ["地域:フランス", "年代:1800-1850"], unreviewed?: true}
      ]

      counts = Chidori.Relations.unreviewed_by_partition(collection, nodes)
      assert counts == %{"日本|-" => 2, "フランス|-" => 1}

      assert RelationsLive.unreviewed_in(%{partition_unreviewed: counts}, "日本|-") == 2
      assert RelationsLive.unreviewed_in(%{partition_unreviewed: counts}, "無い区画") == 0
    end

    test "画家の区画は、押したときに割り出して頼む" do
      test_pid = self()

      collection = %{
        "name" => "chidori_painters",
        "partitions" => [%{"key" => "日本|-", "count" => 3}]
      }

      Chidori.HttpStub.stub(fn
        %{method: :post, url: url, body: body} ->
          send(test_pid, {:focus, url, Jason.decode!(body)})
          Chidori.HttpStub.ok("{}")

        %{url: url} ->
          if String.ends_with?(url, "/v1/collect"),
            do: Chidori.HttpStub.ok(Jason.encode!(%{"collections" => [collection]})),
            else: Chidori.HttpStub.ok(Jason.encode!(collection))
      end)

      assert {:ok, "日本|-"} =
               Chidori.Relations.ask_painter_partition("http://chiezo.test", "誰か", [
                 "地域:日本",
                 "年代:1900-1950"
               ])

      assert_received {:focus, _url, body}
      assert body["sweep"] == "ざっと見る"
      assert body["partition"] == "日本|-"
      assert body["note"] =~ ~r/^日本\|- の区画を先にざっと見て/
    end

    test "ざっと見るの指示文は、区画の名前で始める" do
      note = RelationsLive.partition_note("日本|-", "", Chidori.Relations.rough_sweep())
      assert note =~ ~r/^日本\|- の区画を先にざっと見て/
    end

    test "ざっと見るの巡回として、区画を名指しして頼む" do
      test_pid = self()

      Chidori.HttpStub.stub(fn %{method: :post, url: url, body: body} ->
        send(test_pid, {:focus, url, Jason.decode!(body)})
        Chidori.HttpStub.ok("{}")
      end)

      assert :ok = Chidori.Relations.ask_partition("http://chiezo.test", "日本|-", "先に", "ざっと見る")
      assert_received {:focus, url, body}
      assert url =~ "/focus"
      assert body["sweep"] == "ざっと見る"
      assert body["partition"] == "日本|-"
    end
  end

  describe "設定欄" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      :ok
    end

    test "開くまでは Chiezo から設定を読まず、読み終えるまでは設定を出さない", %{conn: conn} do
      test_pid = self()

      Chidori.HttpStub.stub(fn %{url: url} ->
        cond do
          String.contains?(url, "/v1/collect") or String.contains?(url, "/v1/ai/backends") ->
            # 読みに来たことを知らせて、テストが許すまで待つ
            send(test_pid, {:settings_asked, self()})

            receive do
              :go -> Chidori.HttpStub.ok(~s({"collections":[],"backends":[]}))
            after
              5_000 -> {:error, :timeout}
            end

          # **図は読めるようにしておく。** 空だと、理由を切り分けるために図の側が
          # 収集の設定を読みに来る（それは設定欄とは別の、正しい動き）
          true ->
            Chidori.HttpStub.ok(
              Jason.encode!(%{
                "results" => [%{"title" => "設定欄の画家", "tags" => ["画家"], "body" => "説明"}],
                "total" => 1
              })
            )
        end
      end)

      assert wait_until(fn -> Chidori.Relations.current("painters").status != :loading end)
      Chidori.Relations.refresh("painters")

      assert wait_until(fn ->
               relation = Chidori.Relations.current("painters")
               settled?(relation) and Enum.any?(relation.nodes, &(&1.name == "設定欄の画家"))
             end)

      flush()
      {:ok, live, html} = live(conn, ~p"/relations?view=painters")

      # 開いただけでは読まない
      refute html =~ "collect-form"
      refute_receive {:settings_asked, _pid}, 300

      html = live |> element("#settings-toggle") |> render_click()
      assert html =~ "Chiezo から情報を取得しています"
      refute html =~ "collect-form"

      # 読み終えたら設定が出る（2 つの問い合わせの両方を通す）
      for _ <- 1..2 do
        assert_receive {:settings_asked, pid}, 2_000
        send(pid, :go)
      end

      assert wait_until(fn -> has_element?(live, "form#collect-form") end)
      refute render(live) =~ "Chiezo から情報を取得しています"
    end
  end

  describe "画家の区画の一覧" do
    test "ざっと見ると整理の印を巡回ごとに持つ" do
      # 1 本の巡回の印だけを出すと、まだ回っていないほうの「まだ」が全区画に並ぶ
      state = %{
        collection: %{
          partitions: [
            %{key: "日本|-", count: 3, visits: %{"ざっと見る" => "2026-09-20T00:00:00+00:00"}},
            %{key: "フランス|-", count: 2, visits: %{}}
          ]
        }
      }

      [first, second] = ChidoriWeb.Collect.partition_rows(state, ["ざっと見る", "整理"])

      # まだ見ていないものが先
      assert first.key == "フランス|-"
      assert first.seen_at == %{}
      assert second.seen_at["ざっと見る"] =~ "2026-09-20"
      refute Map.has_key?(second.seen_at, "整理")
    end
  end

  describe "未レビューの数がいつのものか" do
    test "図を取得した時刻を出す（見た印より古いことがあるため）" do
      at = ~U[2026-09-25 00:53:00Z]
      assert ChidoriWeb.RelationsLive.unreviewed_as_of(%{checked_at: at}) =~ "2026-09-25 09:53"
      assert ChidoriWeb.RelationsLive.unreviewed_as_of(%{}) == "まだ取得していません"
    end
  end

  describe "設定欄の頭" do
    alias ChidoriWeb.RelationsLive

    test "読めているときは状態の一文を出さず、読めなかったときだけ理由を出す" do
      assert RelationsLive.trouble_message(%{status: :ready, reason: nil}) == nil

      assert RelationsLive.trouble_message(%{status: :stale, reason: :chiezo_unavailable}) =~
               "接続できません"
    end

    test "出どころは Chiezo で育てる図に出す（収集の名前つき）" do
      assert RelationsLive.origin_note("painters") =~ "Chiezo に溜まった内容から作っています"
      assert RelationsLive.origin_note("people") =~ "chidori_people"
    end
  end

  describe "この画家を詳しく調べてもらう" do
    alias ChidoriWeb.RelationsLive

    test "断られたら、その理由を出す" do
      # **黙って捨てない。** 取り込みが走っている間の割り込みは Chiezo が受け付けない
      # ので、捨てると「頼んだのに何も起きない」だけが残る（実際にそうなった）
      relation = %{focus: %{painter: "モネ", state: :failed, reason: :chiezo_busy}}
      asked = RelationsLive.focus_state(relation, "モネ")

      assert asked.state == :failed
      assert RelationsLive.focus_error(asked) =~ "取り込み中"
    end

    test "別の画家のぶんは出さない" do
      relation = %{focus: %{painter: "モネ", state: :failed, reason: :chiezo_busy}}
      assert RelationsLive.focus_state(relation, "ゴッホ") == nil
    end

    test "まだ何も頼んでいなければ何も出さない" do
      assert RelationsLive.focus_state(%{}, "モネ") == nil
      assert RelationsLive.focus_error(%{painter: "モネ", state: :sent}) == nil
    end
  end

  describe "動いたものだけ" do
    alias Chidori.Relations.Graph
    alias ChidoriWeb.RelationsLive

    defp painters(stamps) do
      for {name, stamp} <- stamps do
        %{
          "title" => name,
          "body" => "説明",
          "tags" => ["画家", "年代:1800-1900"],
          "updated_at" => stamp
        }
      end
    end

    test "動いた件数と時刻を一言で出す" do
      graph =
        Graph.from_docs(
          painters([
            {"モネ", "2026-09-11T15:59:11+00:00"},
            {"ダ・ヴィンチ", "2026-09-01T00:00:00+00:00"}
          ])
        )

      note = RelationsLive.changed_note(graph)
      assert note =~ "1 件"
      # 時刻は日本時間で出す（+09:00）
      assert note =~ "2026-09-12 00:59 JST"
    end

    test "動いたものが無ければ何も言わない" do
      # 最初の一括作成。**比べる先が無い**ので、件数を出しても読む人には何も言えていない
      graph = Graph.from_docs(painters([{"モネ", "2026-09-01T00:00:00+00:00"}]))
      assert RelationsLive.changed_note(graph) == nil
    end

    test "押している間は、動いたものだけで置き直した図を描く" do
      graph =
        Graph.from_docs(
          painters([
            {"モネ", "2026-09-11T15:59:11+00:00"},
            {"ダ・ヴィンチ", "2026-09-01T00:00:00+00:00"}
          ])
        )

      all = RelationsLive.shown(graph, %{changed_only: false, style_filter: nil})
      only = RelationsLive.shown(graph, %{changed_only: true, style_filter: nil})

      assert length(all.nodes) == 2
      assert Enum.map(only.nodes, & &1.name) == ["モネ"]
    end
  end

  describe "探して寄る" do
    alias ChidoriWeb.RelationsLive

    test "選んだ人と繋がっている相手は、小さくても描く" do
      # 周りの関連図を読むために寄っているので、小さいという理由で消えては用をなさない
      focus = %{id: "a", x: 10, y: 10, radius: 1, kind: :artist}
      neighbour = %{id: "b", x: 20, y: 20, radius: 1, kind: :artist}
      other = %{id: "c", x: 30, y: 30, radius: 1, kind: :artist}

      relation = %{
        nodes: [focus, neighbour, other],
        edges: [%{from: "a", to: "b", kind: :related, label: nil}]
      }

      viewport = %{x: 0, y: 0, w: 400, h: 400, ppu: 1.0}

      # 焦点が無ければ、小さすぎて 1 つも描かれない
      assert RelationsLive.drawn_nodes(relation, viewport) == []

      drawn = RelationsLive.drawn_nodes(relation, viewport, "a") |> Enum.map(& &1.id)
      assert "a" in drawn
      assert "b" in drawn
      refute "c" in drawn
    end

    test "繋がりの無い人を選んでも、その人だけは描く" do
      focus = %{id: "a", x: 10, y: 10, radius: 1, kind: :artist}
      relation = %{nodes: [focus], edges: []}
      viewport = %{x: 0, y: 0, w: 400, h: 400, ppu: 1.0}

      assert [%{id: "a"}] = RelationsLive.drawn_nodes(relation, viewport, "a")
    end

    test "名前に含まれるかで探し、知られている順に返す", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      html = live |> form(".relation-search", %{q: "ゴッホ"}) |> render_change()
      assert html =~ "ゴッホ"
    end

    test "空の検索では候補を出さない", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      html = live |> form(".relation-search", %{q: ""}) |> render_change()
      refute html =~ "relation-matches"
    end

    test "検索をやめると焦点も外れる", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      live |> form(".relation-search", %{q: "ゴッホ"}) |> render_change()
      html = live |> element(~s|button[phx-click="clear_search"]|) |> render_click()

      refute html =~ "relation-matches"
    end
  end

  describe "区画の一覧" do
    # 区画の並べ方はどの収集でも同じなので、共有の側にある
    alias ChidoriWeb.Collect
    alias ChidoriWeb.RelationsLive

    test "まだ見ていない区画が先に並ぶ" do
      # 並びがそのまま「次に回ってくる順」になる
      relation = %{
        collection: %{
          partitions: [
            %{key: "日本|1900-1910", count: 25, visits: %{"整理" => "2026-09-01T00:00:00Z"}},
            %{key: "フランス|1840-1869", count: 24, visits: %{}},
            %{key: "イタリア|1500-1600", count: 20, visits: %{"整理" => "2026-08-01T00:00:00Z"}}
          ]
        }
      }

      assert Enum.map(Collect.partition_rows(relation, "整理"), & &1.key) ==
               ["フランス|1840-1869", "イタリア|1500-1600", "日本|1900-1910"]
    end

    test "区画を持たない図では空" do
      assert Collect.partition_rows(%{collection: nil}, "整理") == []
    end

    test "頼みごとは必ず区画の名前で始まる" do
      # 指示文だけを読んだ人には、どこ宛てか分からない
      assert RelationsLive.partition_note("日本|1900-1910", nil) =~ "日本|1900-1910"
      assert RelationsLive.partition_note("日本|1900-1910", "年代を埋めて") =~ "年代を埋めて"
    end

    test "取り直している最中は、取得中だと分かる" do
      # 読んでいるあいだは `status` が :loading。途中経過（`step`）だけを見ていた頃は、
      # 取得中もボタンが押せるままだった
      assert RelationsLive.reloading?(%{status: :loading, step: nil})
      assert RelationsLive.reloading?(%{status: :ready, step: :collecting})
      refute RelationsLive.reloading?(%{status: :ready, step: nil})
      refute RelationsLive.reloading?(%{status: :ready, step: %{}})
    end

    test "整理の既定の頼みごとは、いつもの手順を全部書く" do
      # 割り込みは「次の指示にだけ従って」と前置きされる。「調べて」だけだと、
      # 消したものの見直しに手を付けない
      note = RelationsLive.partition_note("日本|1900-1910", "")
      assert note =~ ~r/^日本\|1900-1910 の区画を/
      assert note =~ "消し間違いが無いか見直す"
    end

    test "消えた画家を戻す頼みごとは、名前・理由・戻す印を書く" do
      note = RelationsLive.restore_note("消えた人", "範囲に入らない", "")
      assert note =~ ~r/^消えた人について。/
      assert note =~ "「範囲に入らない」という理由で"
      assert note =~ "_chiezo_restore"
      assert RelationsLive.restore_note("消えた人", "", "年代は 1980 頃") =~ "補足: 年代は 1980 頃"
    end
  end

  describe "見た記録" do
    alias Chidori.Relations.Mark
    alias Chidori.Relations.Marks

    test "書いた印が、次に開いたときにも出ている", %{conn: conn} do
      {:ok, _} =
        Marks.put("painters", "クロード・モネ", %{
          "seen" => true,
          "seen_on" => "2026-09-12",
          "note" => "回顧展で見た"
        })

      # **図はまだ Chiezo から読めていなくても、印だけは読めている必要がある** ——
      # 印は Chidori が持っているもので、向こうの都合で消えてはいけない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      assert %Mark{note: "回顧展で見た"} = :sys.get_state(live.pid).socket.assigns.marks["クロード・モネ"]
    end

    test "見た日の既定は日本時間の今日", %{conn: _conn} do
      # UTC で動くコンテナでは、日本の朝 9 時までが前日になる
      assert RelationsLive.seen_on_value(%Mark{}) == Date.to_iso8601(Chidori.Jst.today())
      assert RelationsLive.seen_on_value(%Mark{seen_on: ~D[2026-01-02]}) == "2026-01-02"
    end

    test "見た印の付いたものが、行き先の一覧に並ぶ" do
      relation = %{
        nodes: [%{name: "クロード・モネ"}, %{name: "エドガー・ドガ"}, %{name: "誰も見ていない人"}]
      }

      marks = %{
        "クロード・モネ" => %Mark{seen: true, seen_on: ~D[2026-09-01]},
        "エドガー・ドガ" => %Mark{seen: true, seen_on: ~D[2026-09-10]},
        # 図に出ていないものは並べない（選んでも動かない行き先になる）
        "図にいない人" => %Mark{seen: true}
      }

      assert RelationsLive.seen_options(relation, marks) == [
               {"エドガー・ドガ", "エドガー・ドガ（2026-09-10）"},
               {"クロード・モネ", "クロード・モネ（2026-09-01）"}
             ]
    end

    test "日付を書いていない印は後ろに回る" do
      relation = %{nodes: [%{name: "あ"}, %{name: "い"}]}
      marks = %{"あ" => %Mark{note: "行きたい"}, "い" => %Mark{seen: true, seen_on: ~D[2020-01-01]}}

      assert RelationsLive.seen_options(relation, marks) == [
               {"い", "い（2020-01-01）"},
               {"あ", "あ"}
             ]
    end

    test "印の一言は、見たかどうかとメモの有無で変わる" do
      assert RelationsLive.mark_summary(%Mark{seen: true, seen_on: ~D[2026-09-12]}) ==
               "見た（2026-09-12）"

      assert RelationsLive.mark_summary(%Mark{seen: true}) == "見た"
      assert RelationsLive.mark_summary(%Mark{note: "行きたい"}) == "メモあり"
      assert RelationsLive.mark_summary(%Mark{}) == nil
    end
  end

  describe "取り直している最中" do
    alias ChidoriWeb.RelationsLive

    test "ほかの操作を受け付けない" do
      # 届いた図はいま見ているものを丸ごと入れ替えるので、途中で押されたことは
      # 黙って上書きされる —— 押せたのに効かない、という形になる
      assert RelationsLive.busy?(%{step: %{"painters" => "読んでいます"}})
    end

    test "読み終えていれば、ふつうに操作できる" do
      refute RelationsLive.busy?(%{step: %{}})
      refute RelationsLive.busy?(%{step: nil})
      refute RelationsLive.busy?(%{})
    end

    test "覆いだけでなく、操作そのものを止める", %{conn: conn} do
      # 見た目だけ止めても、タブ送りでは押せてしまう。
      # 前のテストが頼んだ読み直しが終わってから開く（走っている間は止まっているのが正しい）
      # 前のテストのスタブが応答を止めていることがある（1 回最長 5 秒で、読み直しの中で
      # 何度か続けて当たる）ので、長めに待つ。**待つのは読み直しが終わるまで**なので、
      # ふだんはすぐ抜ける
      assert wait_until(fn -> settled?(Chidori.Relations.current("painters")) end, 1500)
      {:ok, _live, html} = live(conn, ~p"/relations")

      refute html =~ "is-busy"
      refute html =~ "inert"
    end

    test "立ち直る前のプロセスが走らせたタスクの途中経過は受け取らない" do
      # 途中経過は名前で送られるので、入れ替わったあとのプロセスにも届く。
      # 受けてしまうと、畳む合図は来ないので取り直し中のまま固まる
      restart_relations()
      send(Process.whereis(Chidori.Relations), {:progress, "painters", :reading})

      assert Chidori.Relations.current("painters").step == nil
    end
  end
end
