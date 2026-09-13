defmodule Antenna.Topics do
  @moduledoc """
  話題（最新情報の画面のタブ）。

  **話題は antenna の機能で、利用者のデータではありません。** 関連図の「人物」「画家」と
  同じ立ち位置で、集め方も関心も話題ごとに違う —— だから**定義はコードに置きます**
  (`defined/0`)。DB に持たせていた頃は、コードに足した話題が**既に使っている環境へ
  永遠に届きませんでした**（最初の 1 回だけ配る作りだったため。実際、技術のタブが
  出ないまま気づかれずにいた）。

  **DB は持ちません。** 話題ごとに持つ設定はもう無く、誰に頼むかは巡回ごとに
  画面の表から選んで Chiezo へ送ります —— 収集の設定を持っているのは Chiezo なので、
  こちらに写しを置くと、どちらが本物か分からなくなります。
  """

  @doc """
  antenna が持っている話題。**この並びがタブの並び**。

  足すときはここへ 1 つ書きます（関連図のタブを足すのと同じ手順）。
  `collection` は Chiezo のソース名になるので、**後から変えない** ——
  変えると、それまで溜めた先を見失います。

  `feeds` は機械で引く配信元（RSS / Atom）。**書いてあれば、集めるのは機械の仕事**に
  なります（`Antenna.News` が「見出し」の巡回として Chiezo へ渡す）。空なら AI が集めます。
  """
  def defined do
    [
      %{
        name: "ニュース",
        collection: Antenna.News.collection_name(),
        interest: "暮らし・社会・経済への影響が大きいこと",
        # 一般の報道は、機械で引ける配信元が話題の広さに追いつかない。
        # ここは AI に集めさせる（外の道具を付けるなら、下と同じ形で書ける）
        feeds: []
      },
      %{
        name: "技術ニュース",
        collection: "antenna_tech",
        interest:
          "ソフトウェア開発・インフラ・AI の新しい動き。" <>
            "作る人の判断が変わるもの(言語やフレームワークの新版、設計の定石の変化、" <>
            "使えるようになった道具、対処のいる不具合や脆弱性)を優先する",
        # **機械で引ける配信元は機械で引く。** 見出し・要約・URL・配信日は
        # 機械が正確に取れるので、AI の枠は「何が重要か」「どうまとめるか」へ回す。
        # タグは同じ収集の中で束を分けるためのもの（ニュースと記事を混ぜて溜めて、
        # 後から分けて取り出せるように）
        feeds: [
          %{url: "https://www.publickey1.jp/atom.xml", tags: ["ニュース"]},
          %{url: "https://rss.itmedia.co.jp/rss/2.0/news_bursts.xml", tags: ["ニュース"]},
          %{url: "https://feed.infoq.com/jp/", tags: ["ニュース"]},
          %{url: "https://codezine.jp/rss/new/20/index.xml", tags: ["ニュース"]},
          %{url: "https://zenn.dev/feed", tags: ["記事"]},
          %{url: "https://qiita.com/popular-items/feed", tags: ["記事"]},
          %{url: "https://b.hatena.ne.jp/hotentry/it.rss", tags: ["記事"]}
        ]
      }
    ]
  end

  @doc "話題の一覧（定義の順）。そのままタブの並びになります。"
  def list, do: defined()

  @doc "1 つぶん。定義に無い名前なら nil。"
  def get(collection) when is_binary(collection) do
    Enum.find(defined(), &(&1.collection == collection))
  end

  def get(_collection), do: nil
end
