defmodule Chidori.Datasets.RecipesTest do
  @moduledoc """
  レシピ集（`Chidori.Datasets.Recipes`）。見ているのは、**名簿を機械で引く指定**、
  **AI が書いた本文を見出しで読めること**（少しずれた書き方も読む）、
  **書いた料理だけを並べること**、**画面の絞り込み**です。
  """

  use Chidori.DataCase, async: false

  alias Chidori.Datasets.Recipes
  alias ChidoriWeb.RecipeBook

  @body """
  どんな料理か: ローマの卵とチーズのパスタ。
  正統とされる形: 卵黄・グアンチャーレ・ペコリーノ・ロマーノ・黒胡椒で作り、生クリームは使わない。
  **材料（2人分）**:
  - スパゲッティ 200g
  - グアンチャーレ 80g（無ければパンチェッタ）
  ## 作り方：
  1. グアンチャーレを弱火で炒めて脂を出す。
  2. 火から下ろしてから卵液と和える。
  よくあるアレンジとの違い: 日本では生クリームを入れることが多い。
  出典:
  - https://example.com/carbonara（料理学校の解説）
  - https://example.org/roma
  """

  describe "名簿の引き方" do
    test "「〜料理」の分類を知名度で絞り、料理でない分類を外し、地域を食文化から付ける" do
      spec = Recipes.extract(1_000)

      assert spec.source == "jawiki"
      assert spec.tag_suffix == "料理"
      assert spec.min_extra == %{pageviews_month: 1_000}
      assert spec.not_tag =~ "ラーメン店"
      assert spec.not_tag =~ "地域別の料理"
      assert %{const: "レシピ"} in spec.tags
      assert %{pattern: "^(.+?)の食文化$", format: "地域:{1}"} in spec.tags
      assert "image" in spec.extra
    end

    test "既定の下限は月 1,000（画面で変えたものがあればそれ）" do
      assert Recipes.min_pageviews() == 1_000
      {:ok, _} = Chidori.Relations.Settings.put_min_pageviews("recipes", 500)
      assert Recipes.min_pageviews() == 500
    end

    test "送る設定: 網羅・写真を縮めて持つ・料理名の順に区画を切る・名簿は足すだけ" do
      attrs = Recipes.attrs()

      assert attrs.kind == "stock"
      assert attrs.thumbs == true
      assert attrs.partition == %{by: "title", target: 20}
      assert [%{use_extract: true, only_new: true, once: true} | _] = attrs.sweeps
      assert Enum.all?(tl(attrs.sweeps), &is_binary(&1.prompt))
    end

    test "依頼文に、正統の根拠と書く形と種類の語彙が載る" do
      for prompt <- [Recipes.write_prompt(), Recipes.review_prompt()] do
        assert prompt =~ "正統とされる形"
        assert prompt =~ "個人のレシピブログ"
        assert prompt =~ "あなたの言葉"
        assert prompt =~ "「主菜」、「副菜」"
        assert prompt =~ "{current}"
      end
    end
  end

  describe "本文を読む" do
    test "見出しで区切り、材料・手順・出典を行に分ける（見出しの書き方のずれも読む）" do
      s = Recipes.body_sections(@body)

      assert s.about == "ローマの卵とチーズのパスタ。"
      assert s.canon =~ "生クリームは使わない"
      assert s.servings == "2人分"
      assert s.ingredients == ["スパゲッティ 200g", "グアンチャーレ 80g（無ければパンチェッタ）"]
      assert s.steps == ["グアンチャーレを弱火で炒めて脂を出す。", "火から下ろしてから卵液と和える。"]
      assert s.variants =~ "生クリーム"

      assert s.sources == [
               %{url: "https://example.com/carbonara", label: "料理学校の解説"},
               %{url: "https://example.org/roma", label: ""}
             ]
    end

    test "百科事典の冒頭のままのもの（見出しが無い）は、まだ書いていないとして並べない" do
      written = Recipes.to_recipe(%{"title" => "カルボナーラ", "tags" => ["レシピ"], "body" => @body})
      raw = Recipes.to_recipe(%{"title" => "ラザニア", "tags" => ["レシピ"], "opening" => "ラザニアは…"})

      assert written.written?
      refute raw.written?
    end

    test "タグから国・地域・種類・食材を読み、写真は Chiezo の縮めたものと Commons の頁を指す" do
      recipe =
        Recipes.to_recipe(%{
          "title" => "カルボナーラ",
          "tags" => ~w(レシピ 地域:ローマ 国:イタリア 種類:麺・パスタ 食材:卵 食材:豚肉 定説:あり),
          "body" => @body,
          "extra" => %{
            "thumb" => "/v1/thumbs/" <> String.duplicate("a", 40) <> ".webp",
            "image" =>
              "https://upload.wikimedia.org/wikipedia/commons/3/33/Espaguetis_carbonara.jpg"
          }
        })

      assert {recipe.country, recipe.regions, recipe.kind} == {"イタリア", ["ローマ"], "麺・パスタ"}
      assert recipe.ingredients_tags == ["卵", "豚肉"]
      assert recipe.thumb == "/thumbs/" <> String.duplicate("a", 40) <> ".webp"

      assert recipe.image_page ==
               "https://commons.wikimedia.org/wiki/File:Espaguetis_carbonara.jpg"

      assert RecipeBook.facts(recipe) == "イタリア・ローマ / 麺・パスタ"
    end
  end

  describe "読み込み" do
    setup do
      System.put_env("CHIEZO_BASE_URL", "http://chiezo.example")
      on_exit(fn -> System.delete_env("CHIEZO_BASE_URL") end)
    end

    test "500 件ずつページを送って読み、書いた料理だけを料理名の順に返す" do
      Chidori.HttpStub.stub(fn %{url: url} ->
        query = url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
        offset = String.to_integer(query["offset"])
        count = if offset == 0, do: 500, else: 2

        docs =
          for i <- 1..count//1 do
            body = if rem(i, 2) == 0, do: @body, else: "まだ冒頭のまま"
            %{"title" => "料理#{offset + i}", "tags" => ["レシピ"], "body" => body}
          end

        Chidori.HttpStub.ok(Jason.encode!(%{"results" => docs, "total" => 502}))
      end)

      assert {:ok, recipes} = Recipes.list("http://chiezo.example")
      assert length(recipes) == 251
      assert Enum.map(recipes, & &1.title) == Enum.sort(Enum.map(recipes, & &1.title))
    end
  end

  describe "画面の絞り込み" do
    import Phoenix.LiveViewTest

    defp recipe(title, country, kind, ingredients),
      do: %{title: title, country: country, kind: kind, ingredients_tags: ingredients}

    test "種類は一致、語は料理名と主な食材の部分一致" do
      all = [
        recipe("カルボナーラ", "イタリア", "麺・パスタ", ["卵", "豚肉"]),
        recipe("親子丼", "日本", "ご飯もの", ["鶏肉", "卵"]),
        recipe("ラタトゥイユ", "フランス", "副菜", ["ナス"])
      ]

      # 国では絞らない（国ごとに畳んで並べる）
      assert length(RecipeBook.filtered(all, %{"country" => "日本"})) == 3
      assert ["カルボナーラ", "親子丼"] = all |> RecipeBook.filtered(%{"q" => "卵"}) |> Enum.map(& &1.title)
      assert [%{title: "ラタトゥイユ"}] = RecipeBook.filtered(all, %{"kind" => "副菜", "q" => ""})
    end

    test "国ごとに、品数の多い国から組にする（国の分からない料理は最後）" do
      all = [
        recipe("ピザ", "イタリア", "主菜", []),
        recipe("親子丼", "日本", "ご飯もの", []),
        recipe("謎の料理", nil, "主菜", []),
        recipe("カルボナーラ", "イタリア", "麺・パスタ", []),
        recipe("書いた国が不明", "不明", "主菜", []),
        # 書き方の揺れは 1 つの国にまとめる
        recipe("ハンバーガー", "アメリカ", "主菜", []),
        recipe("ガンボ", "アメリカ合衆国", "汁物", []),
        recipe("ジャンバラヤ", "アメリカ合衆国", "ご飯もの", [])
      ]

      assert [
               {"アメリカ合衆国", [_, _, _]},
               {"イタリア", [%{title: "ピザ"}, %{title: "カルボナーラ"}]},
               {"日本", [_]},
               {"国の分からない料理", [%{title: "謎の料理"}, %{title: "書いた国が不明"}]}
             ] = RecipeBook.by_country(all)
    end

    test "国は畳んで並べ、種類か語で絞っているときは畳まない（国の絞り込みは置かない）" do
      all = [recipe("カルボナーラ", "イタリア", "麺・パスタ", ["卵"]) |> Map.put(:thumb, nil)]
      all = Enum.map(all, &Map.merge(&1, %{regions: []}))

      html = render_component(&RecipeBook.book/1, recipes: all)
      assert html =~ ~r|<details[^>]*class="recipe-country"|
      assert html =~ "イタリア"
      refute html =~ ~s(name="country")

      html = render_component(&RecipeBook.book/1, recipes: all, filter: %{"q" => "卵"})
      refute html =~ "<details"
      assert html =~ "カルボナーラ"
    end
  end

  describe "料理の種類" do
    test "語彙の片方だけを書いた種類は、その語彙に寄せる" do
      # 依頼文で語彙を「・」でつないでいた頃、AI は「麺・パスタ」を 2 つと読んで片方だけを書いた
      assert Recipes.to_kind("パスタ") == "麺・パスタ"
      assert Recipes.to_kind("パン") == "パン・粉もの"
      assert Recipes.to_kind("粉もの") == "パン・粉もの"
      assert Recipes.to_kind("主菜") == "主菜"
      assert Recipes.to_kind("未知") == "未知"
      assert Recipes.to_kind(nil) == nil
    end

    test "依頼文は語彙を 1 つずつ括って並べる" do
      [sweep | _] = Enum.filter(Recipes.attrs().sweeps, &is_binary(&1[:prompt]))
      assert sweep.prompt =~ "「麺・パスタ」、"
    end

    test "一覧は種類ごとに、語彙の順で組にする（種類の無いものは「その他」）" do
      recipes = [
        %{title: "プリン", kind: "菓子・デザート"},
        %{title: "親子丼", kind: "ご飯もの"},
        %{title: "ハンバーグ", kind: "主菜"},
        %{title: "謎", kind: nil}
      ]

      assert [{"主菜", [_]}, {"ご飯もの", [_]}, {"菓子・デザート", [_]}, {"その他", [%{title: "謎"}]}] =
               RecipeBook.grouped(recipes)
    end
  end

  describe "画面" do
    import Phoenix.LiveViewTest

    test "一覧は写真と料理名、開くと材料・手順・出典と写真の出典が出る" do
      recipe =
        Recipes.to_recipe(%{
          "title" => "カルボナーラ",
          "tags" => ~w(レシピ 国:イタリア 種類:麺・パスタ 定説:あり),
          "body" => @body,
          "extra" => %{
            "thumb" => "/v1/thumbs/" <> String.duplicate("b", 40) <> ".webp",
            "image" => "https://upload.wikimedia.org/wikipedia/commons/3/33/Sample.jpg",
            "url" => "https://ja.wikipedia.org/wiki/Sample"
          }
        })

      html = render_component(&RecipeBook.book/1, recipes: [recipe], opened: "カルボナーラ")

      assert html =~ "レシピ集"
      assert html =~ ~s(phx-value-title="カルボナーラ")
      assert html =~ "材料<span>（2人分）</span>"
      assert html =~ "火から下ろしてから卵液と和える。"
      assert html =~ "料理学校の解説"
      assert html =~ "https://commons.wikimedia.org/wiki/File:Sample.jpg"

      # 名簿を引き直す口は収集の画面に置く（読むレシピ集には出さない）
      refute html =~ "名簿を引き直す"
    end

    test "名簿を引き直す口は、収集の画面に置く部品として出す" do
      html = render_component(&RecipeBook.roster_form/1, message: "名簿を引き直しました")

      assert html =~ "名簿を引き直す"
      assert html =~ ~s(phx-submit="reroster_recipes")
      assert html =~ "名簿を引き直しました"
    end
  end
end
