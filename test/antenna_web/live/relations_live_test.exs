defmodule AntennaWeb.RelationsLiveTest do
  use AntennaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "人物の関連図を表示する", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations")

    assert html =~ "人物のつながり"
    # **表示例の図は描かない。** 本物と見分けが付かないので、読み込みが終わるまで
    # 手書きの関連図が出て「これは何」になる（実際にそう言われた）
    assert html =~ "まだ読み込んでいません"
    refute html =~ "松田優作"
  end

  test "画家の関連図へ切り替えられる", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/relations")

    html = live |> element(~s|a[href="/relations?view=painters"]|) |> render_click()

    assert html =~ "画家の影響と時代"
    # **誰が出るかは Chiezo 次第**なので、名前では見ない（前のテストが読み込んだ図が
    # 残っていると落ちる）。切り替わったことは、見出しと図の器で分かる
    assert html =~ "relation-canvas"
    assert html =~ "様式の色" or html =~ "この図の見方"
  end

  test "知らない種類は人物の図に丸める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations?view=%2E%2E%2F")

    assert html =~ "人物のつながり"
  end

  describe "押した合図" do
    test "開いたときの読み直し中は、押せるまま", %{conn: conn} do
      # **読むだけなので止める理由が無い。** 一緒くたに :loading で止めていた頃は、
      # 開くたびに数秒ボタンが押せず、しかも「送っています」と嘘が出ていた
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      Antenna.HttpStub.stub(fn
        # **止めるのは図を読むところだけ。** 相手の一覧は別に引いているので、
        # そちらまで止めると、解放し忘れが次のテストへ持ち越す
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Antenna.HttpStub.ok(~s({"backends":[]}))

        _request ->
          # 応答を止めたまま、止めている自分を教える（終わらせるのはテスト側）
          send(test_pid, {:asked, self()})

          receive do
            :go -> Antenna.HttpStub.ok(~s({"results":[],"total":0}))
          after
            5_000 -> {:error, :timeout}
          end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

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

               Antenna.Relations.current("painters").status != :loading
             end)
    end

    test "Chiezo が取り込み中でも押せる（知らせるだけ）", %{conn: conn} do
      # **ボタンが集めさせていた頃の名残で止めていた。** いまは送るだけなので、
      # 取り込みが走っていても困らない。走っていることは知らせる —— 図がもうすぐ
      # 変わるので、いま読んでいるものが最新でないと分かる
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

      Antenna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ingest/status"} ->
          Antenna.HttpStub.ok(~s({"state":"running","running":true,"source":"antenna_painters"}))

        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Antenna.HttpStub.ok(~s({"results":[],"total":0}))
          else
            Antenna.HttpStub.ok(~s({"collections":[]}))
          end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      assert wait_until(fn -> render(live) =~ "いま Chiezo が取り込み中です" end)
      refute live |> element("form[phx-submit=collect] button") |> render() =~ "disabled"
    end

    test "いま何をしているのかを出す", %{conn: conn} do
      # 押しても数分は Chiezo 側に何も出ない（先に AI へ指定を書かせるため）。
      # 「収集中…」だけだと、押せていないのと区別が付かない
      restart_relations()
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      Antenna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ingest/status"} ->
          Antenna.HttpStub.ok(~s({"running":false}))

        %{method: :post, url: "http://chiezo.test:7010/v1/collect/draft-extract"} ->
          send(test_pid, {:asked, self()})

          receive do
            :go -> Antenna.HttpStub.ok(~s({"extract":{"source":"jawiki","tag":"x"}}))
          after
            5_000 -> {:error, :timeout}
          end

        %{method: :post} ->
          Antenna.HttpStub.ok("{}")

        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Antenna.HttpStub.ok(~s({"results":[],"total":0}))
          else
            Antenna.HttpStub.ok(~s({"collections":[]}))
          end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      assert wait_until(fn -> render(live) =~ "収集の設定を更新" end)

      # ボタンは「送る設定」と同じ枠に入っているので、フォームごと送る
      live |> element("form[phx-submit=collect]") |> render_submit(%{})

      assert_receive {:asked, worker}, 2_000
      assert wait_until(fn -> render(live) =~ "AI に抽出の指定を書かせています" end)
      # 待っているあいだ、Chiezo 側にはまだ何も出ないことも書いておく
      assert render(live) =~ "Chiezo 側にはまだ何も出ません"

      send(worker, :go)
    end

    test "押した合図はサーバーの応答を待たずに出す", %{conn: conn} do
      # 集まるものが無い日は往復が一瞬で終わる。状態の変化だけに任せると、
      # 押したのかどうかが画面に残らない
      {:ok, _live, html} = live(conn, ~p"/relations?view=painters")

      assert html =~ ~s(phx-disable-with="送っています…")
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

      Antenna.HttpStub.stub(fn
        %{url: url} ->
          if String.contains?(url, "/filter?") do
            Antenna.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => 1}))
          else
            Antenna.HttpStub.ok(Jason.encode!(%{"collections" => []}))
          end
      end)

      # 図の状態は全体で1つなので、直前のテストの読み直しが終わるのを待ってから頼む
      # （走っている間の依頼は捨てられるので、頼んでもすぐには始まらない）
      assert wait_until(fn -> Antenna.Relations.current("painters").status != :loading end)
      Antenna.Relations.refresh("painters")
      assert wait_until(fn -> Antenna.Relations.current("painters").status == :ready end)

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

  # **収集の状態は 1 つのプロセスに溜まる。** 押した時刻も覚えているので、
  # 前のテストが押していると次のテストが「少し待ってから」で弾かれる（並びで
  # 結果が変わる）。押すテストは、まっさらな状態から始める
  defp restart_relations do
    :ok = Supervisor.terminate_child(Antenna.Supervisor, Antenna.Relations)
    {:ok, _pid} = Supervisor.restart_child(Antenna.Supervisor, Antenna.Relations)
    :ok
  end

  defp wait_until(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_until(check, tries - 1)
    end
  end

  describe "線の座標" do
    alias AntennaWeb.RelationsLive

    test "エッジごとに両端の座標を返す" do
      relation = %{
        nodes: [%{id: "a", x: 10, y: 20}, %{id: "b", x: 30, y: 60}],
        edges: [%{from: "a", to: "b", kind: :influence, label: "光"}]
      }

      assert [line] = RelationsLive.edge_lines(relation, relation.nodes)
      assert {line.x1, line.y1, line.x2, line.y2} == {10, 20, 30, 60}
      assert line.label == "光"

      # 線の上に出す札の位置も一緒に出す（テンプレートで計算し直さない）
      assert line.mid_x == 20
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
    alias AntennaWeb.RelationsLive

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
        "name" => "antenna_painters",
        "enabled" => true,
        "prompt" => "x",
        "cursor" => "",
        "extract" => %{"source" => "jawiki", "tag" => "画家"},
        "sweeps" => [
          %{"name" => "ざっと", "interval_minutes" => 360, "enabled" => true, "backend" => "claude"},
          %{"name" => "じっくり", "interval_minutes" => 1440, "enabled" => true},
          %{"name" => "割り込み", "on_demand" => true, "enabled" => true}
        ]
      }

      {Jason.encode!(%{"collections" => [item]}), Jason.encode!(item)}
    end

    defp stub_chiezo(test_pid) do
      {collections, one} = painters_collection_json()

      Antenna.HttpStub.stub(fn
        %{url: "http://chiezo.test:7010/v1/ai/backends"} ->
          Antenna.HttpStub.ok(
            ~s({"backends":[{"id":"codex","label":"Codex","models":[],"efforts":["low","high"]},{"id":"claude","label":"Claude","models":[],"efforts":["low","medium","high"]}]})
          )

        %{url: "http://chiezo.test:7010/v1/ingest/status"} ->
          Antenna.HttpStub.ok(~s({"running":false}))

        %{method: :patch, body: body} ->
          send(test_pid, {:patched, body})
          Antenna.HttpStub.ok("{}")

        %{method: :post} ->
          Antenna.HttpStub.ok("{}")

        %{url: url} ->
          cond do
            String.contains?(url, "/filter?") -> Antenna.HttpStub.ok(~s({"results":[],"total":0}))
            String.ends_with?(url, "/v1/collect") -> Antenna.HttpStub.ok(collections)
            true -> Antenna.HttpStub.ok(one)
          end
      end)
    end

    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      stub_chiezo(self())
      restart_relations()
    end

    test "選んだ相手が、図が届いても元に戻らない", %{conn: conn} do
      # **これが「選んだのに反映されない」の正体だった。** フォームの中身を
      # サーバーが覚えていないと、図や状態が届いた拍子に描き直されて、
      # 選んだところが Chiezo に入っている値へ戻る（選んだつもりで押すと、
      # いま入っている値がそのまま送り返される）
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      assert wait_until(fn -> render(live) =~ "ざっと" end)

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|ざっと|backend" => "codex", "sweep|ざっと|effort" => "high"})

      # 図が届いたことにして描き直す（実際には読み直しが終わったとき）
      send(live.pid, {:relation_updated, Antenna.Relations.current("painters")})
      html = live |> element("form#collect-form table") |> render()

      assert html =~ ~s(<option value="codex" selected=)
      assert html =~ ~s(<option value="high" selected=)
    end

    test "時計を持たない巡回にも相手を選べる", %{conn: conn} do
      # 画家のモーダルから頼む「詳しく調べて」は割り込みとして走る。**人が待っている
      # 場面**なので、定時の巡回と同じ相手を使う理由が無い
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      assert wait_until(fn -> render(live) =~ "割り込み" end)

      html = live |> element("form#collect-form table") |> render()
      assert html =~ "時計なし"
      assert html =~ "頼まれたとき"
      assert html =~ ~s(name="sweep|割り込み|backend")
    end

    test "選び直した欄が、前に覚えた値に上書きされない", %{conn: conn} do
      # **一度覚えた欄を二度と変えられなくなっていた。** 相手を選んだ拍子に
      # 「考える量: 空」まで覚え、そのあと考える量を選んでも空のまま送られる ——
      # 画面では選べているように見えるので、押すまで気づけない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      assert wait_until(fn -> render(live) =~ "割り込み" end)

      # まず相手を選ぶ（このとき考える量は空のまま送られてくる）
      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|割り込み|backend" => "codex", "sweep|割り込み|effort" => ""})

      # 次に考える量を選ぶ
      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|割り込み|backend" => "codex", "sweep|割り込み|effort" => "high"})

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      sweep = Enum.find(Jason.decode!(body)["sweeps"], &(&1["name"] == "割り込み"))
      assert sweep["effort"] == "high"
    end

    test "読み直している最中に押しても、設定は送られる", %{conn: conn} do
      # **押下が黙って捨てられていた。** 8,000 件の読み直しは数十秒かかり、そのあいだ
      # ボタンは押せるのに何も起きない —— 画面には何も出ないので、設定が送られて
      # いないことに気づきようがなかった
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      assert wait_until(fn -> render(live) =~ "ざっと" end)

      # 溜まったものの読み出しだけを止めて、読み直しが終わらない状態を作る
      {collections, one} = painters_collection_json()
      test_pid = self()

      Antenna.HttpStub.stub(fn
        %{method: :patch, body: body} ->
          send(test_pid, {:patched, body})
          Antenna.HttpStub.ok("{}")

        %{method: :post} ->
          Antenna.HttpStub.ok("{}")

        %{url: url} ->
          cond do
            String.contains?(url, "/filter?") ->
              send(test_pid, {:reading, self()})

              receive do
                :go -> Antenna.HttpStub.ok(~s({"results":[],"total":0}))
              after
                5_000 -> {:error, :timeout}
              end

            String.ends_with?(url, "/v1/collect") ->
              Antenna.HttpStub.ok(collections)

            String.contains?(url, "/v1/ingest/status") ->
              Antenna.HttpStub.ok(~s({"running":false}))

            true ->
              Antenna.HttpStub.ok(one)
          end
      end)

      Antenna.Relations.refresh("painters")
      assert_receive {:reading, reader}, 2_000
      assert Antenna.Relations.current("painters").status == :loading

      live
      |> element("form#collect-form")
      |> render_change(%{"sweep|ざっと|backend" => "codex"})

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      sweep = Enum.find(Jason.decode!(body)["sweeps"], &(&1["name"] == "ざっと"))
      assert sweep["backend"] == "codex"

      # 止めたままにすると、次のテストへ :loading のまま持ち越す
      send(reader, :go)

      assert wait_until(fn ->
               receive do
                 {:reading, pid} -> send(pid, :go)
               after
                 0 -> :ok
               end

               Antenna.Relations.current("painters").status != :loading
             end)
    end

    test "選んだものが Chiezo へ送られる", %{conn: conn} do
      # **空文字も送る。** あれは「Chiezo の既定にまかせる」を選んだという意思表示で、
      # 落とすと一度決めた相手を画面から外せない
      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")
      assert wait_until(fn -> render(live) =~ "ざっと" end)

      live
      |> element("form#collect-form")
      |> render_change(%{
        "sweep|ざっと|backend" => "codex",
        "sweep|ざっと|effort" => "high",
        "sweep|じっくり|backend" => ""
      })

      live |> element("form#collect-form") |> render_submit(%{})

      assert_receive {:patched, body}, 5_000
      sweeps = Jason.decode!(body)["sweeps"]
      rough = Enum.find(sweeps, &(&1["name"] == "ざっと"))
      deep = Enum.find(sweeps, &(&1["name"] == "じっくり"))

      assert rough["backend"] == "codex"
      assert rough["effort"] == "high"
      assert deep["backend"] == ""
    end
  end

  describe "この画家を詳しく調べてもらう" do
    alias AntennaWeb.RelationsLive

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
    alias Antenna.Relations.Graph
    alias AntennaWeb.RelationsLive

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
    alias AntennaWeb.RelationsLive

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
end
