defmodule Antenna.Fame do
  @moduledoc """
  どれくらい知られているかを、Chiezo の jawiki から引きます。

  **AI に「有名かどうか」を判断させません。** 月次ページビュー（bot 除外）が
  `extra.pageviews_month` に入っているので、そちらのほうが客観的で、
  実行のたびに揺れません。Wikimedia の API を叩く必要もありません。

  引けなかったものは 0 として扱います。**図が出ないより、丸が小さいほうがまし**です。

  **一度引いた値は控えます**（`article_fame`）。Chiezo は記事 1 本につき 1 リクエストしか
  受けないので、図に載せる人数がそのまま往復の数になります（4,250 人なら 4,250 回）。
  ページビューは月次の値で日々変わるものではないため、控えれば 2 回目以降は 0 回で済みます。
  控えが消えても引き直すだけで、失われるのは速さだけです。

  **引けなかったことも控えます**（0 として）。残さないと、値を持たない記事
  （ページビューを持たない・そもそも記事が無い）を毎回引きに行くことになります。
  """

  import Ecto.Query

  alias Antenna.ArticleFame
  alias Antenna.Http
  alias Antenna.Repo

  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"
  @timeout 8_000
  @connect_timeout 5_000

  # 控えを使い回す日数。**月次の値なので日で切って足りる**。短くすると往復が戻り、
  # 長すぎると新しく話題になった人がいつまでも小さいまま
  @fresh_days 7

  # 一度に外へ出す本数。Chiezo は手元にいるが、数千本を一斉に投げると
  # あちらのワーカー（2 本）を占有して、同じ間に開いた別の画面が待たされる
  @concurrency 8

  @doc """
  記事名の並びから「記事名 → 月次ページビュー」を作ります。

  控えにある新しい値はそのまま使い、**足りないものだけ**を Chiezo へ引きに行きます。
  """
  def for_articles(base_url, titles) when is_binary(base_url) and is_list(titles) do
    wanted = titles |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
    cached = cached_views(wanted)
    missing = Enum.reject(wanted, &Map.has_key?(cached, &1))

    fetched = fetch_missing(base_url, missing)
    remember(fetched)

    Map.merge(cached, fetched)
  end

  def for_articles(_base_url, _titles), do: %{}

  # まだ新しい控え。古いものは「無い」として扱い、下で引き直させる
  defp cached_views([]), do: %{}

  defp cached_views(titles) do
    limit = DateTime.add(DateTime.utc_now(), -@fresh_days * 24 * 3600, :second)

    ArticleFame
    |> where([f], f.article in ^titles and f.fetched_at > ^limit)
    |> select([f], {f.article, f.views})
    |> Repo.all()
    |> Map.new()
  rescue
    # 控えが引けなくても図は出す（置き場が無い・移行前など）
    _ -> %{}
  end

  defp fetch_missing(_base_url, []), do: %{}

  defp fetch_missing(base_url, titles) do
    titles
    |> Task.async_stream(&{&1, views(base_url, &1)},
      max_concurrency: @concurrency,
      timeout: @timeout + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      # 引けなかったものも 0 で残す。残さないと毎回引きに行くことになる
      {:ok, {title, views}} when is_integer(views) -> [{title, views}]
      {:ok, {title, nil}} -> [{title, 0}]
      _ -> []
    end)
    |> Map.new()
  end

  defp remember(views) when map_size(views) == 0, do: :ok

  defp remember(views) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    rows = for {article, count} <- views, do: %{article: article, views: count, fetched_at: now}

    Repo.insert_all(ArticleFame, rows,
      on_conflict: {:replace, [:views, :fetched_at]},
      conflict_target: :article
    )

    :ok
  rescue
    # 控えられなくても答えは返す（速くならないだけ）
    _ -> :ok
  end

  defp views(base_url, title) do
    url = base_url <> "/v1/jawiki/doc?fields=title,extra&title=" <> URI.encode_www_form(title)

    with {:ok, %{status: 200, body: body}} <-
           Http.get(url,
             headers: [{"user-agent", @user_agent}],
             timeout: @timeout,
             connect_timeout: @connect_timeout
           ),
         {:ok, %{"extra" => %{"pageviews_month" => views}}} when is_integer(views) <-
           Jason.decode(body) do
      views
    else
      _ -> nil
    end
  end
end
