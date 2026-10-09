defmodule Chidori.Artwork do
  @moduledoc """
  代表作の中身を引きます。**まず Chiezo に聞きます**。

  説明（その作品が何か）も、絵の URL も、Chiezo の jawiki に入っています
  （取り込みが `page_props` ダンプから代表画像を拾って `extra.image` に入れます）——
  外へ聞きに行く理由がありません。

  **入っていないときだけ Wikipedia に聞きます。** 取り込み直す前の長期記憶には
  画像が入っていないので、それまでのつなぎです（入れば自然に使われなくなります）。

  **画像そのものは持ちません**（URL を指すだけ）。取り込んで配ると、絵ごとに違う
  ライセンスをこちらで抱えることになります。

  **引いた結果は覚えます**（同じ画家を何度押しても外へは出ません）。

  **記事の画像は人物の写真になります**（画家の記事の先頭は肖像）。だから引くのは
  **代表作の記事**です。そちらの先頭画像はその絵そのものになります。
  """

  use GenServer

  alias Chidori.Chiezo
  alias Chidori.Http

  @endpoint "https://ja.wikipedia.org/api/rest_v1/page/summary/"
  @user_agent "chidori/0.1 (+https://github.com/rtcode337/chidori)"
  @timeout 10_000
  @connect_timeout 5_000

  # Commons が受け付ける縮小版の横幅。**一覧に無い幅は 400 で断られます** ——
  # 向こうが決まった値だけに絞ったので、好きな幅を頼むことはできません
  # （実測: 80 / 100 / 200 / 320 / 400 / 640 / 800 / 1024 / 2560 はどれも断られる）。
  # ファイルによらず同じ一覧です
  @thumb_widths [20, 40, 60, 120, 250, 330, 500, 960, 1280, 1920]

  # 札に出す大きさ。**原寸は要らない**（絵は数 MB あることがある）。
  # **一覧から選びます** —— 一覧に無い値を書くと、絵が 1 枚残らず消えます
  @thumb_width 500

  @table :tazuna_artwork
  # 覚えておく長さ。**永久には持たない** —— 画像の無かった作品に後から画像が付く
  @ttl_ms 24 * 60 * 60 * 1000

  @doc """
  覚え書きの置き場を持つだけの入れ物。**引くのは呼んだ側のプロセス**で、
  ここには通しません —— 通すと、外が遅い日にここが詰まって全員が待ちます。
  """
  def start_link(options),
    do: GenServer.start_link(__MODULE__, :ok, name: options[:name] || __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  記事名から、絵の URL と短い説明を引きます。取れなければ `nil`。

  **絵が無ければ出しません**（見たいのは絵のほうなので）。説明だけを出しても、
  同じことは画家の記事を読めば分かります。
  """
  def lookup(title) when is_binary(title) do
    case remembered(title) do
      {:ok, found} -> found
      :miss -> remember(title, fetch(title))
    end
  end

  def lookup(_title), do: nil

  defp fetch(title) do
    %{"opening" => opening, "image" => image} = from_chiezo(title)

    case image || from_wikipedia(title) do
      nil -> nil
      found -> %{title: title, image: thumb(found), extract: opening, page: page_of(title)}
    end
  end

  # 説明も絵も、**まず手元の Chiezo から**。同じ記事がこちらにある
  defp from_chiezo(title) do
    with base when is_binary(base) <- Chiezo.base_url(),
         url =
           base <> "/v1/jawiki/doc?fields=title,opening,extra&title=" <>
             URI.encode_www_form(title),
         {:ok, %{status: 200, body: body}} <- get(url),
         {:ok, %{} = doc} <- Jason.decode(body) do
      %{"opening" => trimmed(doc["opening"]), "image" => image_of(doc["extra"])}
    else
      _other -> %{"opening" => nil, "image" => nil}
    end
  end

  defp image_of(%{"image" => image}) when is_binary(image) and image != "", do: image
  defp image_of(_extra), do: nil

  # **取り込み直す前のつなぎ。** 長期記憶に画像が入れば、ここは通らなくなる
  defp from_wikipedia(title) do
    with {:ok, %{status: 200, body: body}} <- get(@endpoint <> encoded(title)),
         {:ok, %{} = summary} <- Jason.decode(body),
         image when is_binary(image) <- get_in(summary, ["thumbnail", "source"]) do
      image
    else
      _other -> nil
    end
  end

  @doc """
  原寸ではなく縮小したものを指します。**札に出すだけなので原寸は要りません**
  （絵は数 MB あることがあり、そのまま指すと開くたびにそれだけ流れます）。

  Commons の縮小版は置き場の規則で決まるので、URL を組み替えるだけで指せます。

  **組み替えられなければ原寸を指します。** 組み替えられないのは、Commons 以外・
  すでに縮小版・`@thumb_widths` に無い幅を頼まれたとき。小さいほうがよいという
  都合より、**絵が出ることのほうが大事**です —— 向こうが受け付ける幅を絞ったとき、
  組み替えた URL は 400 を返すので、そのまま出すと絵が 1 枚残らず消えます。
  """
  def thumb(url, width \\ @thumb_width)

  def thumb(url, width) when is_binary(url) do
    case String.split(url, "/wikipedia/commons/") do
      # すでに縮小版（`thumb/` 配下）なら触らない
      [_head, "thumb/" <> _rest] -> url
      [head, rest] when width in @thumb_widths -> thumb_path(head, rest, Path.basename(rest), width)
      _other -> url
    end
  end

  def thumb(url, _width), do: url

  defp thumb_path(head, rest, name, width) do
    # SVG の縮小版は PNG になる（置き場の規則）
    suffix = if String.ends_with?(String.downcase(name), ".svg"), do: ".png", else: ""
    head <> "/wikipedia/commons/thumb/" <> rest <> "/#{width}px-" <> name <> suffix
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  defp page_of(title), do: "https://ja.wikipedia.org/wiki/" <> encoded(title)

  defp encoded(title), do: URI.encode(String.replace(title, " ", "_"))

  defp get(url) do
    Http.get(url,
      headers: [{"user-agent", @user_agent}],
      timeout: @timeout,
      connect_timeout: @connect_timeout
    )
  end

  # **置き場が無ければ覚えない。** 立てる前に呼ばれても、引けることのほうが大事
  defp remembered(title) do
    with false <- :ets.whereis(@table) == :undefined,
         [{^title, found, until}] <- :ets.lookup(@table, title),
         true <- until > now() do
      {:ok, found}
    else
      _other -> :miss
    end
  end

  defp remember(title, found) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {title, found, now() + @ttl_ms})
    end

    found
  end

  defp now, do: System.monotonic_time(:millisecond)
end
