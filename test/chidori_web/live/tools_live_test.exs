defmodule ChidoriWeb.ToolsLiveTest do
  @moduledoc """
  ツール（`/tools`）。溜めたものを読むのではなく、その場の様子を見る道具を置く
  （いまは Pi-hole の「いま止めている通信」）。
  """

  use ChidoriWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "ツールの画面で、いま止めている通信を流せる", %{conn: conn} do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Chidori.HttpStub.stub(fn %{method: :get, url: url} ->
      body =
        if url =~ "/v1/pihole/blocked",
          do: %{
            "cursor" => 1_759_600_005.0,
            "queries" => [
              %{
                "id" => 1,
                "at" => "2026-10-04T12:00:05+00:00",
                "domain" => "ads.example.com",
                "client" => "192.0.2.10",
                "client_name" => "tablet",
                "status" => "GRAVITY"
              }
            ]
          },
          else: %{"results" => []}

      Chidori.HttpStub.ok(Jason.encode!(body))
    end)

    {:ok, live, html} = live(conn, ~p"/tools")
    assert html =~ "いま止めている通信"
    # 頭のメニューは「ツール」を選んだ状態（収集の左）
    assert html =~ ~r|class="active" href="/tools"|

    live |> element(~s|button[phx-click="start"]|) |> render_click()
    html = render_async(live)

    assert html =~ "ads.example.com"
    assert html =~ "（tablet）"

    # 止めたら、読みに行かない（行は残る）
    html = live |> element(~s|button[phx-click="stop"]|) |> render_click()
    assert html =~ ~s(phx-click="start")
    assert html =~ "ads.example.com"
  end
end
