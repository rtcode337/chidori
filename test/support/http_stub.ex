defmodule Chidori.HttpStub do
  @moduledoc """
  テスト用の HTTP。応答はテストが差し込みます。

  差し込まないまま外へ出ようとしたら失敗させます。取りこぼしを
  「たまたま通った」で済ませないため。
  """

  @behaviour Chidori.Http

  @key :http_stub_responder

  @doc """
  応答を決める関数を差し込みます。`%{method:, url:, body:, opts:}` を受け取り、
  `Chidori.Http` の戻り値を返してください。
  """
  def stub(fun) when is_function(fun, 1) do
    Application.put_env(:chidori, @key, fun)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:chidori, @key) end)
    :ok
  end

  @impl true
  def get(url, opts), do: respond(%{method: :get, url: url, body: nil, opts: opts})

  @impl true
  def post(url, body, opts), do: respond(%{method: :post, url: url, body: body, opts: opts})

  @impl true
  def patch(url, body, opts), do: respond(%{method: :patch, url: url, body: body, opts: opts})

  defp respond(request) do
    case Application.get_env(:chidori, @key) do
      nil -> {:error, :no_stub_configured}
      fun -> fun.(request)
    end
  end

  @doc "そのまま 200 で返す組み立て。"
  def ok(body), do: {:ok, %{status: 200, body: body}}
end
