defmodule ChidoriWeb.DatasetsControllerTest do
  @moduledoc """
  ZIP を書き出せなかったときの応答。**本文は文字だけで返し（HTML として読ませない）、
  中の理由（inspect した値）は出さずにログへ回す**こと。
  """

  use ChidoriWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Chidori.Datasets.DiningAreas

  setup do
    System.put_env("CHIEZO_BASE_URL", "http://chiezo.test")
    on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)

    Chidori.Repo.insert!(%DiningAreas{
      id: 1,
      name: "東京駅のあたり",
      south: 35.67,
      west: 139.75,
      north: 35.69,
      east: 139.78
    })

    Chidori.HttpStub.stub(fn _request -> {:error, :econnrefused} end)
    :ok
  end

  test "書き出せなければ 502 を文字で返し、細かい理由はログにだけ残す", %{conn: conn} do
    log =
      capture_log(fn ->
        conn = get(conn, ~p"/datasets/areas/travel-log.zip")
        send(self(), {:conn, conn})
      end)

    assert_received {:conn, conn}
    assert conn.status == 502
    assert [type | _] = get_resp_header(conn, "content-type")
    assert type =~ "text/plain"
    assert conn.resp_body =~ "書き出せませんでした"
    refute conn.resp_body =~ "{"
    refute conn.resp_body =~ ":"
    assert log =~ "書き出せなかった"
  end
end
