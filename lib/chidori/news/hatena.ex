defmodule Chidori.News.Hatena do
  @moduledoc """
  記事の**はてなブックマーク数**（反応の実数）を引きます。

  **はてなへは Chidori から出ません。** Chiezo の `GET /v1/bookmarks` が取り次ぎ、
  1 回に 50 本ずつ・間を空けて引いて 1 時間覚えます（`Chidori.Chiezo.bookmarks/2`）。
  外への通信先を Chiezo だけにするため。

  **並べ替えに実数を使うため**です。記事に付く「話題度」は整理の回の AI が推し量った
  ものしかなく、並びには使っていませんでした —— 同じ配信元を見ている別のアプリが
  はてブ数で並べていたので、上に来る記事がまるで違っていました。

  **こちらでも覚えておきます**（`@ttl_minutes`）。画面は開くたびに記事を読み直すので、
  そのたびに Chiezo へ聞きに行かないように。**覚えるのはプロセスの中だけ**
  （立て直せば空から始まる。数は後から何度でも引き直せる）。

  **引けなかったら数を持たないだけ**（画面は数の無い記事として出す）。外の都合で
  記事の一覧まで出なくなるのは割に合いません。
  """

  use Agent

  # 覚えておく長さ。**数は 1 時間で大きくは動かない**ので、これ以上細かく引き直しても
  # 並びはほとんど変わらない
  @ttl_minutes 60

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc """
  記事に `bookmarks`（数。引けなければ nil）を載せて返します。並びは変えません。
  """
  def with_counts(articles) when is_list(articles) do
    counts = counts(Enum.map(articles, & &1.url))
    Enum.map(articles, &Map.put(&1, :bookmarks, &1.url && Map.get(counts, &1.url)))
  end

  @doc "URL → はてブ数。覚えているものは引き直さない。引けなかった URL は入らない。"
  def counts(urls) do
    urls = urls |> Enum.filter(&is_binary/1) |> Enum.uniq()
    now = System.monotonic_time(:second)
    known = cached(urls, now)
    missing = Enum.reject(urls, &Map.has_key?(known, &1))

    fetched = if missing == [], do: %{}, else: fetch(missing)

    remember(fetched, now)
    Map.merge(known, fetched)
  end

  @doc "忘れる（テスト用）。"
  def clear do
    if Process.whereis(__MODULE__), do: Agent.update(__MODULE__, fn _ -> %{} end)
    :ok
  end

  # **はてなへは Chidori から出ない**（Chiezo の `GET /v1/bookmarks` が取り次ぐ）
  defp fetch(urls) do
    case Chidori.Chiezo.base_url() do
      nil -> %{}
      base -> Chidori.Chiezo.bookmarks(base, urls)
    end
  end

  defp cached(urls, now) do
    if Process.whereis(__MODULE__) do
      Agent.get(__MODULE__, fn store ->
        for url <- urls,
            {n, at} = Map.get(store, url, {nil, nil}),
            at != nil and now - at < @ttl_minutes * 60,
            into: %{},
            do: {url, n}
      end)
    else
      %{}
    end
  end

  defp remember(fetched, now) do
    if Process.whereis(__MODULE__) && fetched != %{} do
      Agent.update(__MODULE__, fn store ->
        Enum.reduce(fetched, store, fn {url, n}, acc -> Map.put(acc, url, {n, now}) end)
      end)
    end
  end
end
