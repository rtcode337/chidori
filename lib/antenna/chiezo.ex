defmodule Antenna.Chiezo do
  @moduledoc """
  Chiezo とのやり取りのうち、**どの話題でも同じ部分**をまとめたところです。

  収集の定義を読む、依頼する、走らせる —— どれもニュースでも関連図でも同じ形なので、
  ここに 1 つだけ置きます。2 か所に分かれると、片方だけ直す事故が起きます。

  **話題ごとに違うもの**（何を集めるかの指示文、溜まったものをどう見せるか）は
  呼ぶ側が持ちます。
  """

  alias Antenna.Http

  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"
  @timeout 15_000
  @connect_timeout 5_000

  @doc """
  Chiezo のルートURL。未設定ならこの機能は使えません。
  """
  def base_url do
    case System.get_env("CHIEZO_BASE_URL") do
      nil -> nil
      "" -> nil
      value -> value |> String.trim() |> String.trim_trailing("/")
    end
  end

  @doc "Chiezo の画面へのリンク。相対パスをルートURLに繋ぐだけです。"
  def url(path) when is_binary(path) do
    case base_url() do
      nil -> nil
      base -> base <> path
    end
  end

  def url(_path), do: nil

  @doc """
  収集の状態を読みます。**まだ依頼していなければ `nil`**（失敗ではない）。

  一覧を先に見るのは、404 の意味を切り分けるためです —— 収集の口が無い Chiezo と、
  まだ依頼していないだけの状態は、1 件の口だけでは同じ 404 に見えます。
  """
  def collection(base, name, samples \\ 0) do
    with {:ok, collections} <- list(base) do
      case Enum.find(collections, &(&1["name"] == name)) do
        nil -> {:ok, nil}
        found -> detail(base, name, found, samples)
      end
    end
  end

  @doc """
  収集を依頼します。**作られるのは止まった状態**なので、これで AI が動き出すことは
  ありません。すでにあれば何もしません（409 は成功として扱う）。
  """
  def request(base, attrs) do
    case post(base <> "/v1/collect", Jason.encode!(attrs)) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 409}} -> :ok
      {:ok, %{status: 404}} -> {:error, :collect_unsupported}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      # **断られた理由はそのまま通す。** 数字だけ出しても、押した人には
      # 次に何をすればよいか分からない（実際に「400」とだけ出て、Chiezo の版が
      # 古くて新しい集め方を知らない、という理由に辿り着けなかった）
      {:ok, %{status: status, body: body}} -> {:error, {:chiezo_refused, status, reason_of(body)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc false
  # Chiezo は理由を `{"error": "..."}` で返す。読めなければ nil
  def reason_of(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) -> error
      {:ok, %{"detail" => %{"error" => error}}} when is_binary(error) -> error
      _ -> nil
    end
  end

  @doc """
  予定を待たずに1回走らせます。**止まっている収集は Chiezo が断ります**（403）。
  """
  def run(base, name, timeout \\ 600_000) do
    case post(base <> "/v1/collect/" <> name <> "/run", "", timeout) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 403}} -> {:error, :collection_disabled}
      {:ok, %{status: 404}} -> {:error, :not_requested}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      {:ok, %{status: status}} -> {:error, {:chiezo_status, status}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc "溜まった件数。集めたものは長期記憶側にあるので、ソース表から取ります。"
  def docs_count(base, name) do
    with {:ok, %{status: 200, body: body}} <- get(base <> "/v1/sources"),
         {:ok, %{"sources" => sources}} <- Jason.decode(body),
         %{"docs" => docs} <- Enum.find(sources, &(&1["name"] == name)) do
      docs
    else
      _ -> 0
    end
  end

  def get(url, opts \\ []) do
    Http.get(
      url,
      Keyword.merge(
        [
          headers: [{"user-agent", @user_agent}],
          timeout: @timeout,
          connect_timeout: @connect_timeout
        ],
        opts
      )
    )
  end

  def post(url, body, timeout \\ @timeout) do
    Http.post(url, body,
      headers: [{"user-agent", @user_agent}],
      content_type: "application/json",
      timeout: timeout,
      connect_timeout: @connect_timeout
    )
  end

  defp list(base) do
    case get(base <> "/v1/collect") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"collections" => collections}} when is_list(collections) -> {:ok, collections}
          _ -> {:error, :chiezo_unexpected_body}
        end

      # 収集の口そのものが無い Chiezo（層を足す前の版）
      {:ok, %{status: 404}} ->
        {:error, :collect_unsupported}

      # 溜め先が設定されていない Chiezo
      {:ok, %{status: 503}} ->
        {:error, :collect_disabled}

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  defp detail(base, name, fallback, samples) do
    case get(base <> "/v1/collect/" <> name <> "?samples=#{samples}") do
      {:ok, %{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, %{} = detail} ->
            {:ok,
             detail
             |> to_map()
             |> Map.put(:docs, docs_count(base, name))
             |> Map.put(:recent, detail["recent"] || [])}

          _ ->
            {:error, :chiezo_unexpected_body}
        end

      # 一覧には出ていたのに引けないときは、一覧のぶんだけで出す
      {:ok, %{status: _status}} ->
        {:ok, to_map(fallback)}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc false
  # 画面が要る項目だけ取り出す。**Chiezo が持っているものが正** —— 依頼した後は
  # 向こうの画面から変えられるので、antenna 側の雛形を映すと嘘になりうる
  def to_map(%{} = item) do
    %{
      name: item["name"],
      description: item["description"] || "",
      enabled: item["enabled"] == true,
      interval_minutes: item["interval_minutes"],
      next_run_at: item["next_run_at"],
      last_run_at: item["last_run_at"],
      last_status: item["last_status"],
      last_error: item["last_error"],
      last_added: item["last_added"] || 0,
      last_removed: item["last_removed"] || 0,
      mode: item["mode"] || "append",
      prompt: item["prompt"] || "",
      cursor: item["cursor"] || "",
      backend: item["backend"],
      model: item["model"],
      effort: item["effort"],
      docs: 0,
      recent: [],
      requested_by: item["requested_by"] || "",
      url: url(item["url"])
    }
  end

  def to_map(_item), do: nil
end
