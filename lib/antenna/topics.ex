defmodule Antenna.Topics do
  @moduledoc """
  話題（最新情報の画面のタブ）。

  **話題は antenna の機能で、利用者のデータではありません。** 関連図の「人物」「画家」と
  同じ立ち位置で、集め方も関心も話題ごとに違う —— だから**定義はコードに置きます**
  (`defined/0`)。DB に持たせていた頃は、コードに足した話題が**既に使っている環境へ
  永遠に届きませんでした**（最初の 1 回だけ配る作りだったため。実際、技術のタブが
  出ないまま気づかれずにいた）。

  **DB が持つのは設定だけ** —— その話題を誰に頼むか。行は保存したときに作られ、
  定義に無い行は読みません（話題を消したときに、設定だけが残っても害が無いように）。

  **相手は 2 つ持ちます**（集める相手と選ぶ相手）。役割が違うので、速さと質の釣り合いも
  別に決めたい —— 集めるのは web を歩く仕事、選ぶのは溜まったものを読む仕事。
  どちらも未指定なら Chiezo の既定にまかせます。
  """

  alias Antenna.Repo
  alias Antenna.Topics.Topic

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

  @doc """
  話題の一覧（定義の順）。**保存してある設定を重ねて返します**。

  まだ設定していない話題も出ます（相手は Chiezo の既定にまかせる、という状態）。
  """
  def list do
    saved = Map.new(Repo.all(Topic), &{&1.collection, &1})
    Enum.map(defined(), &merge(&1, saved[&1.collection]))
  end

  @doc "1 つぶん。定義に無い名前なら nil。"
  def get(collection) when is_binary(collection) do
    Enum.find(list(), &(&1.collection == collection))
  end

  def get(_collection), do: nil

  @doc """
  その話題の設定を保存します。**行が無ければ作ります**。

  定義に無い話題は保存できません —— 設定だけがあって話題が無い状態を作らないため。
  """
  def save_settings(collection, attrs) when is_binary(collection) do
    case get(collection) do
      nil ->
        {:error, :unknown_topic}

      topic ->
        row = Repo.get_by(Topic, collection: collection) || %Topic{}

        row
        |> Topic.changeset(Map.merge(settings_only(attrs), %{
          "name" => topic.name,
          "collection" => collection
        }))
        |> Repo.insert_or_update()
    end
  end

  @doc "書きかけの入力を持ち回る形。保存はしません。"
  def change(topic, attrs \\ %{}) do
    row = Repo.get_by(Topic, collection: topic.collection) || %Topic{}
    Topic.changeset(row, Map.merge(settings_only(attrs), %{
      "name" => topic.name,
      "collection" => topic.collection
    }))
  end

  # **設定だけを受け取る。** 名前も収集名も関心もコードが持っているので、
  # 画面から送られてきても読まない（読むと、定義と DB が別々に動き出す）
  @settings ~w(collect_backend collect_model collect_effort
               select_backend select_model select_effort)

  defp settings_only(attrs) do
    for {key, value} <- attrs, to_string(key) in @settings, into: %{} do
      {to_string(key), value}
    end
  end

  defp merge(topic, nil), do: Map.merge(blank_settings(), topic)

  defp merge(topic, row) do
    Map.merge(topic, %{
      collect_backend: row.collect_backend,
      collect_model: row.collect_model,
      collect_effort: row.collect_effort,
      select_backend: row.select_backend,
      select_model: row.select_model,
      select_effort: row.select_effort
    })
  end

  defp blank_settings do
    %{
      collect_backend: nil,
      collect_model: nil,
      collect_effort: nil,
      select_backend: nil,
      select_model: nil,
      select_effort: nil
    }
  end
end
