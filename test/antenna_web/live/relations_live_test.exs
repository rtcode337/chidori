defmodule AntennaWeb.RelationsLiveTest do
  use AntennaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "人物の関連図を表示する", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations")

    assert html =~ "人物のつながり"
    assert html =~ "松田優作"
  end

  test "画家の関連図へ切り替えられる", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/relations")

    html = live |> element(~s|a[href="/relations?view=painters"]|) |> render_click()

    assert html =~ "画家の影響と時代"
    assert html =~ "フィンセント・ファン・ゴッホ"
  end

  test "知らない種類は人物の図に丸める", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/relations?view=%2E%2E%2F")

    assert html =~ "人物のつながり"
  end

  describe "押した合図" do
    test "収集中はボタンを押せなくする", %{conn: conn} do
      # 集めるのは向こうなので、終わるまで押しっぱなしにできると二重に頼める
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.test:7010")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
      test_pid = self()

      Antenna.HttpStub.stub(fn _request ->
        # 応答を止めたまま、止めている自分を教える（終わらせるのはテスト側）
        send(test_pid, {:asked, self()})

        receive do
          :go -> Antenna.HttpStub.ok(~s({"results":[],"total":0}))
        after
          5_000 -> {:error, :timeout}
        end
      end)

      {:ok, live, _html} = live(conn, ~p"/relations?view=painters")

      # 開いたときの読み直しが走っている間は、押せない状態になっている
      assert_receive {:asked, worker}, 2_000
      assert wait_until(fn -> render(live) =~ "収集中…" end)
      assert render(live) =~ "disabled"

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

    test "Chiezo が取り込み中のあいだも押せなくする", %{conn: conn} do
      # 走っている間の「いま集めて」は向こうが断る。押してから断られるのと、
      # 押せないことが見えているのとでは別物
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

      assert wait_until(fn -> render(live) =~ "Chiezo が取り込み中…" end)
      assert render(live) =~ "disabled"
    end

    test "押した合図はサーバーの応答を待たずに出す", %{conn: conn} do
      # 集まるものが無い日は往復が一瞬で終わる。状態の変化だけに任せると、
      # 押したのかどうかが画面に残らない
      {:ok, _live, html} = live(conn, ~p"/relations?view=painters")

      assert html =~ ~s(phx-disable-with="収集中…")
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

  defp wait_until(check, tries \\ 100) do
    cond do
      check.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && wait_until(check, tries - 1)
    end
  end
end
