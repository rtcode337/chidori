defmodule Antenna.Http do
  @moduledoc """
  外部への HTTP 取得を1か所にまとめた入口です。

  収集処理がここだけを見るようにしてあるので、テストでは差し替えられます。
  外部へ実際に出ていくテストは、相手の都合で落ちるうえに相手への負担にもなります。
  """

  @type response :: {:ok, %{status: non_neg_integer(), body: binary()}} | {:error, term()}

  @callback get(url :: String.t(), opts :: keyword()) :: response()
  @callback post(url :: String.t(), body :: binary(), opts :: keyword()) :: response()
  @callback patch(url :: String.t(), body :: binary(), opts :: keyword()) :: response()

  @doc """
  いま使う実装。テストは `config/test.exs` でスタブへ差し替えます。
  """
  def impl, do: Application.get_env(:antenna, :http_client, Antenna.Http.Httpc)

  def get(url, opts \\ []), do: impl().get(url, opts)
  def post(url, body, opts \\ []), do: impl().post(url, body, opts)
  def patch(url, body, opts \\ []), do: impl().patch(url, body, opts)
end

defmodule Antenna.Http.Httpc do
  @moduledoc """
  OTP 同梱の `:httpc` を使う実装です。追加の依存を持たずに済みます。

  `:inets` と `:ssl` は `mix.exs` の `extra_applications` に入れてあり、
  リリースにも含まれます。ここでの `start/0` は起動していない場合の保険です。
  """

  @behaviour Antenna.Http

  @default_timeout 20_000
  @default_connect_timeout 5_000

  @impl true
  def get(url, opts) do
    request(:get, {charlist(url), headers(opts)}, opts)
  end

  @impl true
  def post(url, body, opts), do: with_body(:post, url, body, opts)

  @impl true
  def patch(url, body, opts), do: with_body(:patch, url, body, opts)

  defp with_body(method, url, body, opts) do
    content_type = Keyword.get(opts, :content_type, "application/json")

    request(
      method,
      {charlist(url), headers(opts), charlist(content_type), body},
      opts
    )
  end

  defp request(method, request, opts) do
    ensure_started()

    http_options = [
      timeout: Keyword.get(opts, :timeout, @default_timeout),
      connect_timeout: Keyword.get(opts, :connect_timeout, @default_connect_timeout)
    ]

    case :httpc.request(method, request, http_options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    # :httpc は不正な URL などで例外を投げる。呼び出し側を落とさない
    error -> {:error, error}
  end

  defp headers(opts) do
    opts
    |> Keyword.get(:headers, [])
    |> Enum.map(fn {name, value} -> {charlist(name), charlist(value)} end)
  end

  defp ensure_started do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)
    :ok
  end

  defp charlist(value), do: String.to_charlist(value)
end
