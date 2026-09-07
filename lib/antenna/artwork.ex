defmodule Antenna.Artwork do
  @moduledoc """
  代表作の絵を探します。

  **画像そのものは持ちません。** Wikipedia の記事にある画像の URL を引いて、
  画面がそこを指すだけです。取り込んで配ると、絵ごとに違うライセンスを
  こちらで抱えることになります。

  **Chiezo には画像がありません**（取り込みが持っているのは本文・タグ・座標まで）。
  なので、ここだけは外の API を叩きます。押されたときにだけ 1 件引き、
  結果は覚えておくので、同じ人を何度押しても外へは出ません。

  **記事の画像は人物の写真になります**（画家の記事の先頭は肖像）。だから
  引くのは**代表作の記事**です。そちらの先頭画像はその絵そのものになります。
  """

  @endpoint "https://ja.wikipedia.org/api/rest_v1/page/summary/"
  @user_agent "antenna/0.1 (+https://github.com/rtcode337/antenna)"
  @timeout 10_000
  @connect_timeout 5_000

  alias Antenna.Http

  @doc """
  記事名から、画像の URL と短い説明を引きます。

  取れなければ `nil`。**取れないことは普通に起きる**ので（記事が無い、画像が無い）、
  失敗として扱わず、画面は説明だけを出します。
  """
  def lookup(title) when is_binary(title) do
    url = @endpoint <> URI.encode(String.replace(title, " ", "_"))

    with {:ok, %{status: 200, body: body}} <-
           Http.get(url,
             headers: [{"user-agent", @user_agent}],
             timeout: @timeout,
             connect_timeout: @connect_timeout
           ),
         {:ok, %{} = summary} <- Jason.decode(body) do
      image = get_in(summary, ["thumbnail", "source"])

      if is_binary(image) do
        %{
          title: summary["title"] || title,
          image: image,
          extract: summary["extract"],
          page: get_in(summary, ["content_urls", "desktop", "page"])
        }
      end
    else
      _ -> nil
    end
  end

  def lookup(_title), do: nil
end
