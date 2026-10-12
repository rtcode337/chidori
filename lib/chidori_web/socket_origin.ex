defmodule ChidoriWeb.SocketOrigin do
  @moduledoc """
  LiveView の口（`/live/websocket`・`/live/longpoll`）へ来た要求の接続元（`Origin`）を、
  **その要求が届いた宛先**と見比べます。別のサイトに置かれたページが、見ている人の
  ブラウザを使って Chidori の画面へ繋ぎ、ボタンを押したことにする（AI を動かす・
  設定を書き換える）のを止めるためです。

  見比べるのは名前（ホスト）だけで、**どの名前・IP で開いても通ります**。名前を
  並べて許す形にしないのは、VPN 越しの名前や IP で開いたときに締め出さないためです。
  scheme とポートは見ません —— 前段で TLS をほどく逆プロキシを置くと、ブラウザは
  `https://…`（443）を名乗り、Chidori には `http`・7000 で届くので、比べると必ず外れます。

  届いた宛先として認めるのは次のどれかです。

  - 要求の `Host`（`conn.host`）
  - 逆プロキシが付ける `X-Forwarded-Host`（`Host` を書き換えるプロキシのため）
  - `PHX_HOST`（エンドポイントの `url` の host）

  `Origin` の無い要求は通します（ブラウザは WebSocket でも長ポーリングでも付けるので、
  付けないのはブラウザ以外の道具。これを止めても守れるものは無い）。

  切り替えはエンドポイントの設定 `socket_origin`（`config/runtime.exs` が
  `PHX_CHECK_ORIGIN` から決める）。`:same_host` で見比べ、`:off` で見ない
  （宛先を並べたときは Phoenix の `check_origin` に任せるので `:off` になる）。
  """

  import Plug.Conn

  require Logger

  @doc false
  def init(opts), do: opts

  @doc """
  LiveView の口への要求なら接続元を見比べ、外れていれば 403 で止めます（`halted`）。
  それ以外の要求はそのまま返します。
  """
  def call(%Plug.Conn{path_info: ["live" | _rest]} = conn, _opts) do
    if mode(conn.private[:phoenix_endpoint]) == :same_host and not allowed?(conn) do
      Logger.warning(
        "別の接続元からの LiveView の接続を断った: origin=#{inspect(origin(conn))} host=#{inspect(conn.host)}"
      )

      conn |> send_resp(403, "") |> halt()
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  @doc "接続元が、その要求の届いた宛先と同じ名前か（`Origin` が無ければ `true`）。"
  def allowed?(conn) do
    case origin(conn) do
      nil ->
        true

      origin ->
        case URI.parse(origin) do
          %URI{host: host} when is_binary(host) and host != "" ->
            normalize(host) in accepted_hosts(conn)

          _other ->
            false
        end
    end
  end

  defp mode(nil), do: :same_host
  defp mode(endpoint), do: endpoint.config(:socket_origin, :same_host)

  defp origin(conn), do: conn |> get_req_header("origin") |> List.first()

  defp accepted_hosts(conn) do
    forwarded =
      conn
      |> get_req_header("x-forwarded-host")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&host_only/1)

    url_host =
      case conn.private[:phoenix_endpoint] do
        nil -> []
        endpoint -> [endpoint.config(:url)[:host]]
      end

    ([conn.host] ++ forwarded ++ url_host)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&normalize/1)
  end

  # `X-Forwarded-Host` はポートが付くことがある（`example.com:8443`・`[::1]:7000`）
  defp host_only(value) do
    value = String.trim(value)

    case URI.parse("//" <> value) do
      %URI{host: host} when is_binary(host) -> host
      _other -> value
    end
  end

  # IPv6 の角括弧と大文字小文字を揃える
  defp normalize(host),
    do:
      host
      |> String.trim()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.downcase()
end
