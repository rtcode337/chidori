defmodule ChidoriWeb.SocketOriginTest do
  @moduledoc """
  LiveView の口への接続元の見比べ（`ChidoriWeb.SocketOrigin`）。見ているのは、
  **別のサイトのページからの接続を断ること**と、**どの名前・IP で開いても、
  前段に TLS の逆プロキシがあっても繋がること**。
  """

  use ChidoriWeb.ConnCase, async: true

  # 落ちる仕事・断った接続のログは、見ているものではないので出さない
  @moduletag :capture_log

  defp websocket(conn, origin, host \\ "www.example.com") do
    conn
    |> Map.put(:host, host)
    |> put_req_header("origin", origin)
    |> get("/live/websocket?vsn=2.0.0")
  end

  test "別のサイトからの接続は 403 で断る", %{conn: conn} do
    assert websocket(conn, "https://evil.example").status == 403
    assert websocket(conn, "http://www.example.com.evil.example").status == 403

    longpoll =
      conn
      |> put_req_header("origin", "https://evil.example")
      |> get("/live/longpoll?vsn=2.0.0")

    assert longpoll.status == 403
  end

  test "届いた宛先と同じ名前なら、IP でも通す（scheme・ポートは見ない）", %{conn: conn} do
    # 通ったものは Phoenix の口まで届く（WebSocket の握手ではないので 400 になる）
    refute websocket(conn, "http://www.example.com").status == 403
    refute websocket(conn, "http://192.0.2.5:7000", "192.0.2.5").status == 403

    # 逆プロキシで TLS をほどいたとき（ブラウザは https、Chidori には http で届く）
    refute websocket(conn, "https://chidori.example.com", "chidori.example.com").status == 403
  end

  test "Host を書き換える逆プロキシでも、X-Forwarded-Host の名前なら通す", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "127.0.0.1")
      |> put_req_header("x-forwarded-host", "chidori.example.com:443")
      |> put_req_header("origin", "https://chidori.example.com")
      |> get("/live/websocket?vsn=2.0.0")

    refute conn.status == 403
  end

  test "Origin の無い要求と、LiveView の口以外は見ない", %{conn: conn} do
    refute get(conn, "/live/websocket?vsn=2.0.0").status == 403

    page =
      conn
      |> put_req_header("origin", "https://evil.example")
      |> get("/news")

    refute page.status == 403
  end

  test "allowed? は Origin の名前と、届いた宛先の名前を比べる", %{conn: conn} do
    conn = put_req_header(conn, "origin", "https://evil.example")
    assert ChidoriWeb.SocketOrigin.allowed?(conn) == false
    assert ChidoriWeb.SocketOrigin.allowed?(%{conn | host: "evil.example"})
  end
end
