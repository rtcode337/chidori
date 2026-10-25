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

  test "通知を押したら、開いている画面に自分で移ってもらう（iPhone のホーム画面アプリ向け）" do
    # service worker からは移せないことがあるので、画面に頼み、返事が無ければ別の手で移す
    sw = File.read!(Application.app_dir(:chidori, "priv/static/sw.js"))
    assert sw =~ ~s(postMessage({type: "chidori:navigate", url})
    assert sw =~ "same.navigate(url)"
    assert sw =~ "openWindow(url)"

    app = File.read!(Path.expand("../../assets/js/app.js", __DIR__))
    assert app =~ ~s(data.type !== "chidori:navigate")
    assert app =~ "url.origin !== window.location.origin"
  end

  test "通知の行き先を書き置き、画面が前に出たときに読んで移る（裏で止まっていて頼みが届かないとき）" do
    sw = File.read!(Application.app_dir(:chidori, "priv/static/sw.js"))
    # 開いている画面を探すより先に書き置く
    {note, _} = :binary.match(sw, "await leaveNote(url)")
    {find, _} = :binary.match(sw, "self.clients.matchAll")
    assert note < find
    assert sw =~ ~s(const NAV_CACHE = "chidori-nav")

    app = File.read!(Path.expand("../../assets/js/app.js", __DIR__))
    assert app =~ ~s(const NAV_CACHE = "chidori-nav")
    assert app =~ ~s|window.addEventListener("pageshow", takeNavigation)|
    assert app =~ ~s|document.visibilityState === "visible"|
    # 古い書き置き・よそのサイト・いまの画面そのものへは移らない
    assert app =~ "Date.now() - note.at > NAV_FRESH_MS"

    assert app =~
             "url.pathname + url.search === window.location.pathname + window.location.search"
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
