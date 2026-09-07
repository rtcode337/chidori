defmodule Antenna.Fame do
  @moduledoc """
  どれくらい知られているかを、Chiezo の jawiki から引きます。

  **AI に「有名かどうか」を判断させません。** 月次ページビュー（bot 除外）が
  `extra.pageviews_month` に入っているので、そちらのほうが客観的で、
  実行のたびに揺れません。Wikimedia の API を叩く必要もありません。

  引けなかったものは 0 として扱います。**図が出ないより、丸が小さいほうがまし**です。
  """

  alias Antenna.Http

  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"
  @timeout 8_000
  @connect_timeout 5_000

  @doc """
  記事名の並びから「記事名 → 月次ページビュー」を作ります。

  **1 件ずつ並行に引きます** —— Chiezo は手元にいて 1 件が数ミリ秒なので、
  まとめて引く口を作るより素直です。落ちたものは黙って落とします。
  """
  def for_articles(base_url, titles) when is_binary(base_url) and is_list(titles) do
    titles
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Task.async_stream(&{&1, views(base_url, &1)},
      max_concurrency: 8,
      timeout: @timeout + 2_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {title, views}} when is_integer(views) -> [{title, views}]
      _ -> []
    end)
    |> Map.new()
  end

  def for_articles(_base_url, _titles), do: %{}

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
