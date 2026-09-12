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
  # 指定を書かせるのは AI 1 往復ぶん待つ。しかも Chiezo は、取れた数が足りなければ
  # 実在するタグを見せてもう一度書かせる —— **最悪 2 往復**になる。向こうの 1 往復の
  # 上限が 15 分なので、こちらが 10 分で切ると走っている AI を捨てることになり、
  # 指定が無いまま(= AI が全部書く形で)集め始めてしまう
  @draft_timeout 1_800_000
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

  @doc """
  依頼文から**抽出の指定**を書かせます。**保存はされません**（返るだけ）。

  Chiezo は何を集めているかを知らないので、条件はこちらが言葉で書いて渡します。
  向こうは書けた指定でその場で引いて、何件取れるかと最初の数件を添えて返します。

  **誰に書かせるかは名指しできます**（`who` に `backend` / `model`）。指定を書くのは
  索引を何度も引く仕事なので、遅い相手だと十数分待つことになります。
  """
  def draft_extract(base, name, want, who \\ %{}, timeout \\ @draft_timeout) do
    body = Jason.encode!(Map.merge(%{name: name, want: want}, who))

    case post(base <> "/v1/collect/draft-extract", body, timeout) do
      {:ok, %{status: status, body: raw}} when status in 200..299 -> decoded(raw)
      {:ok, %{status: 404}} -> {:error, :collect_unsupported}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  収集の設定の一部を差し替えます（渡した項目だけ）。
  """
  def patch(base, name, attrs) do
    url = base <> "/v1/collect/" <> name

    case Http.patch(url, Jason.encode!(attrs),
           headers: [{"user-agent", @user_agent}],
           content_type: "application/json",
           timeout: @timeout,
           connect_timeout: @connect_timeout
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 404}} -> {:error, :not_requested}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  @doc """
  **この部分を集中的に直して**、を Chiezo へ割り込ませます。

  定時の巡回とは別の道で、進み具合にも次の予定にも触りません。名指しした画家は
  必ず AI に見せられます（区画を渡すだけでは、直してほしい 1 人が差し込みに載る
  保証がない）。
  """
  def focus(base, name, note, titles) do
    body = Jason.encode!(%{note: note, titles: titles, requested_by: "antenna"})

    case post(base <> "/v1/collect/" <> name <> "/focus", body, @timeout) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 403}} -> {:error, :collection_disabled}
      {:ok, %{status: 404}} -> {:error, :not_requested}
      {:ok, %{status: 409}} -> {:error, :chiezo_busy}
      {:ok, %{status: 503}} -> {:error, :collect_disabled}
      {:ok, %{status: status, body: raw}} -> {:error, {:chiezo_refused, status, reason_of(raw)}}
      {:error, _reason} -> {:error, :chiezo_unavailable}
    end
  end

  defp decoded(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = value} -> {:ok, value}
      _ -> {:error, :chiezo_unexpected_body}
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

  @doc """
  Chiezo でいま取り込みが走っているか。走っている間は「いま集めて」を断られます。

  **押してから断られるのと、押せないことが見えているのとでは別物**なので、
  押す前に確かめられるようにしてあります。読めなければ「走っていない」に倒します
  （この問い合わせが失敗しただけで押せなくなるほうが困る）。
  """
  def ingesting?(base) do
    case get(base <> "/v1/ingest/status") do
      {:ok, %{status: 200, body: body}} ->
        match?({:ok, %{"running" => true}}, Jason.decode(body))

      _ ->
        false
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
      # 最初の 1 回を機械的に埋める指定（持っていなければ nil）。
      # 何で埋まったのかは画面に出したいので、状態と一緒に持ち回る
      extract: item["extract"],
      backend: item["backend"],
      model: item["model"],
      effort: item["effort"],
      # 巡回（ざっと / じっくり）。**相手も区画の進み具合も巡回ごとに違う**ので、
      # 収集に 1 つだけ持たせると、そこに出る値はどちらか片方のものにしかならない
      sweeps: sweeps_of(item),
      partitions_total: item["partitions_total"] || 0,
      docs: 0,
      recent: [],
      requested_by: item["requested_by"] || "",
      url: url(item["url"])
    }
  end

  def to_map(_item), do: nil

  defp sweeps_of(%{"sweeps" => list}) when is_list(list) do
    for s <- list, is_map(s) do
      %{
        name: s["name"] || "",
        backend: s["backend"],
        model: s["model"],
        effort: s["effort"],
        interval_minutes: s["interval_minutes"],
        cover_days: s["cover_days"],
        partitions_per_run: s["partitions_per_run"],
        # 時計を持たない巡回（割り込み用）。定時には走らず、頼まれたときだけ動く
        on_demand: s["on_demand"] == true,
        enabled: s["enabled"] != false,
        next_run_at: s["next_run_at"],
        last_run_at: s["last_run_at"],
        last_status: s["last_status"],
        last_error: s["last_error"],
        partitions_visited: s["partitions_visited"] || 0
      }
    end
  end

  defp sweeps_of(_item), do: []

  @doc """
  Chiezo で頼める相手の一覧。**画面の選択肢に使う**ので、向こうが有効にしている
  ものだけが返ります（無効な相手を選べても、走らせた瞬間に断られる）。

  引けなければ空。**選べないだけで、図は出ます**。
  """
  def backends(base) do
    case get(base <> "/v1/ai/backends") do
      {:ok, %{status: 200, body: raw}} ->
        case Jason.decode(raw) do
          {:ok, %{"backends" => list}} when is_list(list) ->
            for b <- list, is_map(b), b["id"] do
              %{
                id: b["id"],
                label: b["label"] || b["id"],
                models: b["models"] || [],
                efforts: b["efforts"] || []
              }
            end

          _ ->
            []
        end

      _ ->
        []
    end
  end
end
