defmodule ChidoriWeb.RecipeBook do
  @moduledoc """
  レシピ集を読むところ（データ収集の「レシピ」のタブ。`Chidori.Datasets.Recipes`）。

  **一覧は写真と料理名だけ、押したら詳細を重ねて開く**（作品の詳細と同じ動き）。
  **一覧は国ごとに畳み**（品数の多い国から。`by_country/1`）、国の中は料理の種類ごとに見出しを
  立てて並べる（主菜 → 副菜 → … の語彙の順。`grouped/1`）—— 全部を開いて並べると数百品が
  続いて、どの国の料理があるのか見渡せない。名前順に混ぜると主菜とお菓子と調味料が隣り合う。
  国の絞り込みは置かない（国を開けば足りる）。種類・語（料理名と主な食材）で絞っているときは
  畳まずに、当てはまる料理を国の見出しの下に並べる（畳んだままだと、当たったのか分からない）。

  押したときの動き（`filter_recipes` / `open_recipe` / `close_recipe` / `reroster_recipes`）は
  置いた画面（`ChidoriWeb.DatasetsLive`）が受けます。
  """

  use ChidoriWeb, :html

  alias Chidori.Datasets.Recipes

  attr :recipes, :list, required: true
  attr :filter, :map, default: %{}
  attr :opened, :string, default: nil
  attr :message, :string, default: nil

  def book(assigns) do
    assigns =
      assign(assigns,
        shown: filtered(assigns.recipes, assigns.filter),
        narrowed: filtered?(assigns.filter),
        kinds: kind_counts(assigns.recipes),
        recipe: Enum.find(assigns.recipes, &(&1.title == assigns.opened))
      )

    ~H"""
    <section class="recipe-book" aria-label="レシピ集">
      <h2>
        レシピ集 <span class="muted-note">（{length(@recipes)} 品）</span>
      </h2>
      <p :if={@recipes == []} class="muted-note">
        まだありません。収集の画面から依頼して有効にすると、名簿の回が百科事典から料理を引き、書く回が 1 品ずつレシピを書いていきます（書き終えた料理から並びます）。
      </p>
      <form :if={@recipes != []} class="recipe-filters" phx-change="filter_recipes">
        <label>
          種類
          <select name="kind">
            <option value="">すべて</option>
            <option :for={{kind, n} <- @kinds} value={kind} selected={@filter["kind"] == kind}>
              {kind}（{n}）
            </option>
          </select>
        </label>
        <label>
          料理名・食材
          <input
            type="search"
            name="q"
            value={@filter["q"]}
            placeholder="例: 卵"
            phx-debounce="300"
          />
        </label>
      </form>
      <p :if={@recipes != [] and @shown == []} class="muted-note">当てはまる料理はありません。</p>
      <%!-- 国ごとに畳む。開け閉めはブラウザに任せる（料理を開いて描き直しても、開いた国が閉じないように） --%>
      <details
        :for={{country, list} <- by_country(@shown)}
        :if={!@narrowed}
        class="recipe-country"
        id={"recipe-country-" <> country_id(country)}
        phx-mounted={Phoenix.LiveView.JS.ignore_attributes(["open"])}
      >
        <summary>{country} <span class="muted-note">（{length(list)} 品）</span></summary>
        <.kind_groups recipes={list} />
      </details>
      <%!-- 絞っているときは畳まない --%>
      <section :for={{country, list} <- by_country(@shown)} :if={@narrowed} class="recipe-country">
        <h3>{country} <span class="muted-note">（{length(list)} 品）</span></h3>
        <.kind_groups recipes={list} />
      </section>

      <.recipe_modal :if={@recipe} recipe={@recipe} />
    </section>
    """
  end

  attr :recipes, :list, required: true

  # 国の中の、種類ごとの組と料理の札
  defp kind_groups(assigns) do
    ~H"""
    <section :for={{kind, list} <- grouped(@recipes)} class="recipe-kind">
      <h4>{kind} <span class="muted-note">（{length(list)} 品）</span></h4>
      <ul class="recipe-grid">
        <li :for={recipe <- list}>
          <button
            type="button"
            class="recipe-card"
            phx-click="open_recipe"
            phx-value-title={recipe.title}
          >
            <img :if={recipe.thumb} src={recipe.thumb} alt="" loading="lazy" />
            <span :if={!recipe.thumb} class="recipe-noimage" aria-hidden="true"></span>
            <strong>{recipe.title}</strong>
            <span class="muted-note">{facts(recipe)}</span>
          </button>
        </li>
      </ul>
    </section>
    """
  end

  attr :message, :string, default: nil

  @doc """
  名簿の広さ（収集の画面に置く。読む画面のレシピ集からは外した —— 頼む口は収集の画面に集める）。
  """
  def roster_form(assigns) do
    ~H"""
    <%!-- 名簿の広さ。**足すだけ**の引き直しなので、下げると広がり、上げても減らない --%>
    <form class="recipe-roster" phx-submit="reroster_recipes">
      <label>
        名簿の広さ（百科事典の月の閲覧数の下限）
        <select name="min">
          <option
            :for={n <- Recipes.pageview_choices()}
            value={n}
            selected={n == Recipes.min_pageviews()}
          >
            月 {Integer.to_string(n)} 以上
          </option>
        </select>
      </label>
      <button type="submit" phx-disable-with="引き直しています…">名簿を引き直す</button>
      <span class="muted-note">
        AI を使わずに名簿だけ引き直します（足すだけなので、下限を上げても名簿からは消えません）。足した料理は書く回が順に書きます。
      </span>
      <span :if={@message} class="muted-note">{@message}</span>
    </form>
    """
  end

  attr :recipe, :map, required: true

  @doc "1 品の詳細（重ねて開く）。"
  def recipe_modal(assigns) do
    ~H"""
    <div
      class="artwork-backdrop work-modal-backdrop"
      phx-window-keydown="close_recipe"
      phx-key="Escape"
    >
      <section
        id="recipe-modal"
        class="artwork work-modal recipe-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="recipe-modal-title"
        phx-click-away="close_recipe"
      >
        <div class="artwork-head">
          <strong id="recipe-modal-title">{@recipe.title}</strong>
          <button type="button" phx-click="close_recipe">閉じる</button>
        </div>
        <p class="muted-note">{facts(@recipe)}</p>
        <figure :if={@recipe.thumb} class="recipe-photo">
          <img src={@recipe.thumb} alt={@recipe.title} class="work-modal-thumb" />
          <figcaption :if={@recipe.image_page} class="muted-note">
            写真:
            <a href={@recipe.image_page} target="_blank" rel="noopener">Wikimedia Commons（撮影者とライセンス）</a>
          </figcaption>
        </figure>

        <% s = @recipe.sections %>
        <p :if={s[:about]}>{s[:about]}</p>
        <h3 :if={s[:canon]}>
          正統とされる形 <span :if={@recipe.canon == "なし"} class="seen-badge">定説はない</span>
        </h3>
        <p :if={s[:canon]}>{s[:canon]}</p>
        <h3 :if={s[:ingredients]}>
          材料<span :if={s[:servings]}>（{s[:servings]}）</span>
        </h3>
        <ul :if={s[:ingredients]} class="recipe-ingredients">
          <li :for={line <- s[:ingredients]}>{line}</li>
        </ul>
        <h3 :if={s[:steps]}>作り方</h3>
        <ol :if={s[:steps]} class="recipe-steps">
          <li :for={line <- s[:steps]}>{line}</li>
        </ol>
        <h3 :if={s[:variants]}>よくあるアレンジとの違い</h3>
        <p :if={s[:variants]}>{s[:variants]}</p>
        <div class="work-modal-refs">
          <h3>出典</h3>
          <ul>
            <li :for={source <- s[:sources] || []}>
              <a :if={source.url} href={source.url} target="_blank" rel="noopener">
                {if source.label != "", do: source.label, else: source.url}
              </a>
              <span :if={!source.url}>{source.label}</span>
            </li>
            <li :if={@recipe.url}>
              <a href={@recipe.url} target="_blank" rel="noopener">日本語版 Wikipedia の記事</a>
            </li>
          </ul>
          <p class="muted-note">
            文章は AI が出典に当たって自分の言葉で書いたものです。材料と手順は出典で確かめてください。
          </p>
        </div>
      </section>
    </div>
    """
  end

  @doc "一覧と詳細に添える事実の一言（国・地域・種類）。"
  def facts(recipe) do
    place =
      case {recipe.country, recipe.regions} do
        {nil, []} -> nil
        {nil, regions} -> Enum.join(regions, "・")
        {country, regions} -> Enum.join(Enum.uniq([country | regions]), "・")
      end

    [place, recipe.kind] |> Enum.reject(&is_nil/1) |> Enum.join(" / ")
  end

  @doc """
  絞り込み。種類は一致、語は料理名と主な食材の部分一致（大文字小文字は区別しない）。
  """
  def filtered(recipes, filter) do
    kind = blank(filter["kind"])
    q = filter["q"] |> blank() |> then(&(&1 && String.downcase(&1)))

    Enum.filter(recipes, fn recipe ->
      (is_nil(kind) or recipe.kind == kind) and
        (is_nil(q) or
           Enum.any?(
             [recipe.title | recipe.ingredients_tags],
             &String.contains?(String.downcase(&1), q)
           ))
    end)
  end

  defp blank(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank(_value), do: nil

  @doc "種類か語で絞っているか（絞っているときは国を畳まない）。"
  def filtered?(filter), do: blank(filter["kind"]) != nil or blank(filter["q"]) != nil

  @doc """
  国ごとの組（`[{国, [レシピ]}]`）。品数の多い国から（同じ数なら名前順）、国の分からない料理
  （国が無いか「不明」）はいちばん後ろの「国の分からない料理」へ。組の中は渡された順のまま。
  同じ国の書き方の揺れ（`@country_aliases`）は 1 つの組にまとめる（AI が書いた国のタグに
  「アメリカ」と「アメリカ合衆国」が混ざっていて、同じ国が 2 つの組に割れた）。
  """
  def by_country(recipes) do
    {known, unknown} =
      recipes
      |> Enum.map(&{country_of(&1), &1})
      |> Enum.split_with(fn {country, _recipe} -> country != nil end)

    unknown = Enum.map(unknown, &elem(&1, 1))

    known
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(fn {country, list} -> {-length(list), country} end)
    |> Kernel.++(if unknown == [], do: [], else: [{"国の分からない料理", unknown}])
  end

  @country_aliases %{"アメリカ" => "アメリカ合衆国"}

  defp country_of(%{country: country}) when is_binary(country) and country not in ["", "不明"],
    do: Map.get(@country_aliases, country, country)

  defp country_of(_recipe), do: nil

  # 畳んだ国の id（開け閉めをブラウザに任せるには、描き直しても同じ要素だと分かる id が要る）
  defp country_id(country), do: Base.url_encode64(country, padding: false)

  @doc """
  種類ごとの組（`[{種類, [レシピ]}]`）。並びは語彙の順（主菜 → 副菜 → …）、語彙に無い種類は
  その後ろに名前順、種類の無いものは「その他」へ入れる。組の中は渡された順のまま。
  """
  def grouped(recipes) do
    groups = Enum.group_by(recipes, &(&1.kind || "その他"))
    order = Recipes.kinds() ++ (groups |> Map.keys() |> Kernel.--(Recipes.kinds()) |> Enum.sort())

    for kind <- order, list = groups[kind], do: {kind, list}
  end

  # 種類は語彙の並び（多い順ではなく、主菜 → 副菜 → … の決めた順）
  defp kind_counts(recipes) do
    freq = recipes |> Enum.map(& &1.kind) |> Enum.reject(&is_nil/1) |> Enum.frequencies()

    for kind <- Recipes.kinds() ++ (Map.keys(freq) -- Recipes.kinds()),
        n = Map.get(freq, kind),
        do: {kind, n}
  end
end
