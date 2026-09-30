defmodule TazunaWeb.SettingsLiveTest do
  @moduledoc """
  設定ページの「Chiezo 収集」。ここでは**巡回の間隔を画面から変えられること**を見ます。
  """

  use TazunaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tazuna.CollectPace
  alias Tazuna.HttpStub

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")

    on_exit(fn ->
      System.delete_env("CHIEZO_BASE_URL")
      for kind <- CollectPace.kinds(), do: :persistent_term.erase({CollectPace, kind})
    end)

    parent = self()

    HttpStub.stub(fn
      %{method: :get, url: url} ->
        if String.ends_with?(url, "/v1/collect"),
          do:
            HttpStub.ok(
              Jason.encode!(%{
                "collections" => [
                  %{
                    "name" => "tazuna_tech",
                    "sweeps" => [%{"name" => "整理", "interval_minutes" => 720}]
                  }
                ]
              })
            ),
          else: HttpStub.ok(~s({"workers":[],"backends":[]}))

      %{method: :patch, url: url, body: body} ->
        send(parent, {:patched, URI.decode(url), Jason.decode!(body)})
        HttpStub.ok("{}")
    end)

    :ok
  end

  test "いまの間隔が選ばれて出る", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/settings?tab=chiezo")

    assert html =~ "巡回の間隔"
    assert html =~ ~r/<option[^>]*value="720"[^>]*selected/
  end

  test "保存すると、その間隔を Chiezo に送る", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/settings?tab=chiezo")

    live
    |> form("#collect-pace", pace: %{tidy: "1440", scan: "120"})
    |> render_submit()

    assert CollectPace.minutes(:tidy) == 1440
    assert_receive {:patched, "http://chiezo.test/v1/collect/tazuna_tech/sweeps/整理", body}
    assert body["interval_minutes"] == 1440
    assert render_async(live) =~ "1 本の巡回に送りました"
  end
end
