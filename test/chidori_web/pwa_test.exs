defmodule ChidoriWeb.PwaTest do
  @moduledoc """
  ホーム画面に入れて通知を受けるための置き物（manifest と service worker）。
  **根から素の名前で配れること**を見ます —— service worker は置き場より下しか受け持てず、
  `/assets/` に置くと通知から開く `/news` を受け持てません。
  """

  use ChidoriWeb.ConnCase, async: true

  test "service worker と manifest を根から配る", %{conn: conn} do
    sw = get(conn, "/sw.js")
    assert sw.status == 200
    assert sw.resp_body =~ "notificationclick"

    manifest = get(build_conn(), "/manifest.webmanifest")
    assert manifest.status == 200
    assert %{"start_url" => "/", "display" => "standalone"} = Jason.decode!(manifest.resp_body)
  end

  test "manifest が指すアイコンは、実際に配れる", %{conn: _conn} do
    %{"icons" => icons} =
      :chidori
      |> Application.app_dir("priv/static/manifest.webmanifest")
      |> File.read!()
      |> Jason.decode!()

    for %{"src" => src, "sizes" => sizes} <- icons do
      conn = get(build_conn(), src)
      assert conn.status == 200, src
      # 宣言した大きさと実物が合っている（PNG の IHDR を読む）
      <<_sig::binary-size(16), width::32, height::32, _::binary>> = conn.resp_body
      assert "#{width}x#{height}" == sizes
    end
  end
end
