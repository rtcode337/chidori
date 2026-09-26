defmodule Tazuna.Datasets.BookQueries do
  @moduledoc """
  技術書の記事を探す**検索文を、回ごとに AI に考えさせる**ところ。

  **同じ検索文で引き直しても、同じ記事が返るだけです。** 検索文を固定していた頃は、
  1 回目に 158 件入ったあと、2 回目は 158 件すべてが既にあるもので弾かれました ——
  本を勧める記事はそんなに速くは増えません。そこで決めた時刻ごとに、

  1. 前の回の検索文が、それぞれ何件の記事を連れてきたかを数える（記事に付く
     「#{"検索"}:<検索文>」のタグで数える。数えるのは Chiezo の手元の索引）
  2. これまでの検索文と数を AI に見せて、**まだ試していない切り口**の検索文を考えさせる
  3. その検索文で配信元を書き換え、機械収集を 1 回だけ走らせる

  **AI の仕事は検索文を考えるだけ**です。記事を探し回るのは機械（はてなブックマークの
  検索 RSS）で、入った記事を読むのは整理の回。1 回に使う枠は小さく済みます。

  **控えは tazuna が持ちます**（何を探しているかは tazuna の都合で、Chiezo は持たない）。
  """

  import Ecto.Query

  alias Tazuna.Chiezo
  alias Tazuna.Datasets.SearchQuery
  alias Tazuna.Http
  alias Tazuna.Repo

  # 1 回に載せる検索文の数。**1 つにつき配信元を 2 本使う**（人気順と新着順）ので、
  # Chiezo の上限（20 本）に収まる数
  @per_run 8

  # 記事に付く、どの検索文で入ったかの印の頭
  @query_tag "検索"

  # AI に見せるこれまでの検索文の数（新しい順）
  @history_shown 200

  @request_timeout 300_000
  @connect_timeout 10_000

  @doc "1 回に載せる検索文の数。"
  def per_run, do: @per_run

  @doc "記事に付く、どの検索文で入ったかの印の頭。"
  def query_tag, do: @query_tag

  @doc "いま配信元に載っている検索文（いちばん新しい組）。まだ無ければ空。"
  def current(collection) do
    case last_used_at(collection) do
      nil ->
        []

      at ->
        SearchQuery
        |> where([q], q.collection == ^collection and q.used_at == ^at)
        |> order_by([q], asc: q.id)
        |> select([q], q.query)
        |> Repo.all()
    end
  end

  @doc "これまでの検索文（新しい順）。"
  def history(collection, limit \\ @history_shown) do
    SearchQuery
    |> where([q], q.collection == ^collection)
    |> order_by([q], desc: q.used_at, asc: q.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp last_used_at(collection) do
    SearchQuery
    |> where([q], q.collection == ^collection)
    |> select([q], max(q.used_at))
    |> Repo.one()
  end

  @doc """
  回の頭にすること。**数える → 考えさせる → 控える**。返すのは新しい検索文の並び。

  `seed` は 1 回目に使う検索文（まだ何も控えていないとき）。AI に頼めなかったときは
  `{:error, 理由}` —— **前の検索文のまま走らせても、同じ記事が返るだけ**なので、
  その回は走らせない。
  """
  def refresh(base, collection, seed \\ []) do
    count_found(base, collection)

    case {history(collection), seed} do
      {[], [_ | _]} ->
        record(collection, seed)

      {history, _seed} ->
        with {:ok, proposed} <- propose(base, history) do
          record(collection, proposed)
        end
    end
  end

  @doc """
  前の回の検索文が連れてきた記事の数を控える（記事に付いた「検索:<検索文>」の数）。
  **数えられなかったら控えない**（読めないことと 0 件は別）。
  """
  def count_found(base, collection) do
    with {:ok, counts} <- found_counts(base, collection) do
      for row <- history(collection), is_nil(row.found) do
        row
        |> SearchQuery.changeset(%{found: Map.get(counts, row.query, 0)})
        |> Repo.update()
      end
    end

    :ok
  end

  defp found_counts(base, collection) do
    query = URI.encode_query(%{"prefix" => @query_tag <> ":", "limit" => 1000})

    with {:ok, %{status: 200, body: body}} <-
           Chiezo.get(base <> "/v1/" <> collection <> "/tags?" <> query),
         {:ok, %{"tags" => tags}} when is_list(tags) <- Jason.decode(body) do
      {:ok, for(%{"tag" => @query_tag <> ":" <> q, "docs" => n} <- tags, into: %{}, do: {q, n})}
    else
      # **まだ 1 度も焼いていなければソースごと無い**（0 件として数えてよい）
      {:ok, %{status: 404}} -> {:ok, %{}}
      _unreadable -> :error
    end
  end

  defp record(collection, queries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    used = MapSet.new(history(collection, 10_000), & &1.query)

    fresh =
      queries
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or MapSet.member?(used, &1)))
      |> Enum.uniq()
      |> Enum.take(@per_run)

    case fresh do
      [] ->
        {:error, :no_new_queries}

      fresh ->
        for q <- fresh do
          %SearchQuery{}
          |> SearchQuery.changeset(%{collection: collection, query: q, used_at: now})
          |> Repo.insert!()
        end

        {:ok, fresh}
    end
  end

  @doc """
  AI に新しい検索文を考えさせる。`{:ok, [検索文]}` か `{:error, 理由}`。
  """
  def propose(base, history) do
    payload =
      Jason.encode!(%{
        messages: [%{role: "user", content: prompt(history)}],
        web: false,
        requested_by: "tazuna"
      })

    options = [
      content_type: "application/json",
      timeout: @request_timeout,
      connect_timeout: @connect_timeout
    ]

    case Http.post(base <> "/v1/ai/complete", payload, options) do
      {:ok, %{status: 200, body: body}} ->
        with {:ok, %{"content" => content}} when is_binary(content) <- Jason.decode(body),
             [_ | _] = queries <- parse(content) do
          {:ok, queries}
        else
          _unreadable -> {:error, :chiezo_unexpected_body}
        end

      {:ok, %{status: status}} ->
        {:error, {:chiezo_status, status}}

      {:error, _reason} ->
        {:error, :chiezo_unavailable}
    end
  end

  @doc "AI の答えから検索文の並びを取り出す（JSON の配列。前置きや囲みがあっても拾う）。"
  def parse(content) when is_binary(content) do
    case Regex.run(~r/\[[\s\S]*\]/, content) do
      [json] ->
        case Jason.decode(json) do
          {:ok, list} when is_list(list) -> for q <- list, is_binary(q), do: String.trim(q)
          _other -> []
        end

      _none ->
        []
    end
  end

  @doc "AI への依頼文。"
  def prompt(history) do
    lines =
      Enum.map_join(history, "\n", fn row ->
        found = if is_integer(row.found), do: "#{row.found} 件", else: "まだ数えていない"
        "- #{row.query}（#{found}）"
      end)

    """
    はてなブックマークの全文検索で、**技術書を勧めている記事・技術書を参考文献として
    挙げている記事**を見つけるための検索文を #{@per_run} 個考えてください。

    これまでに使った検索文と、それぞれで新しく入った記事の数です（新しい順）。

    #{if lines == "", do: "（まだありません）", else: lines}

    - **まだ試していない切り口**にしてください（同じ検索文・言い換えただけのものは、
      同じ記事が返るだけです）。記事が多く入った検索文の近くを掘るのは構いません
    - 切り口の例: 分野（設計・DB・ネットワーク・セキュリティ・機械学習…）、
      読み手（新人・リーダー・SRE…）、記事の形（読書記録・書評・輪読会・
      参考文献・年間ベスト…）、言語（英語の記事）
    - 1 つの検索文は 2〜4 語（全文検索なので、長すぎると 1 件も当たりません）

    **JSON の文字列の配列だけ**を返してください（前置きも説明も要りません）。
    例: ["輪読会 技術書", "SRE 本 おすすめ"]
    """
  end
end
