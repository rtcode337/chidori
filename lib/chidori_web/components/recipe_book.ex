defmodule ChidoriWeb.RecipeBook do
  @moduledoc """
  レシピ集を読むところ（データ収集の「レシピ」のタブ。`Chidori.Datasets.Recipes`）。

  **一覧は写真と料理名だけ、押したら詳細を重ねて開く**（作品の詳細と同じ動き）。
  **一覧は料理の種類ごとに見出しを立てて並べる**（主菜 → 副菜 → … の語彙の順。`grouped/1`）——
  名前順に混ぜて並べると、主菜とお菓子と調味料が隣り合って何があるのか読み取れない。
  1 品の本文は材料と手順まであって長いので、一覧に並べると何があるのか見渡せない。
  国・種類・語（料理名と主な食材）で絞れる。

  押したときの動き（`filter_recipes` / `open_recipe` / `close_recipe` / `reroster_recipes`）は
  置いた画面（`ChidoriWeb.DatasetsLive`）が受けます。
  """

  use ChidoriWeb, :html

  alias Chidori.Datasets.Recipes

  attr :recipes, :list, required: true
  attr :filter, :map, default: %{}
  attr :opened, :string, default: nil
  attr :message, :string, default: nil

  # 名簿の広さの欄を出すか（トップでは出さない。設定はデータ収集の画面で）
  attr :roster, :boolean, default: true

  def book(assigns) do
    assigns =
      assign(assigns,
        shown: filtered(assigns.recipes, assigns.filter),
        countries: counts(assigns.recipes, & &1.country),
        kinds: kind_counts(assigns.recipes),
        recipe: Enum.find(assigns.recipes, &(&1.title == assigns.opened))
      )

    ~H"""
    <section class="recipe-book" aria-label="レシピ集">
      <h2>
        レシピ集 <span class="muted-note">（{length(@recipes)} 品）</span>
      </h2>
      <p :if={@recipes == []} class="muted-note">
        まだありません。下の設定から依頼して有効にすると、名簿の回が百科事典から料理を引き、書く回が 1 品ずつレシピを書いていきます（書き終えた料理から並びます）。
      </p>
      <form :if={@recipes != []} class="recipe-filters" phx-change="filter_recipes">
        <label>
          国
          <select name="country">
            <option value="">すべて</option>
            <option
              :for={{country, n} <- @countries}
              value={country}
              selected={@filter["country"] == country}
            >
              {country}（{n}）
            </option>
          </select>
        </label>
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
      <section :for={{kind, list} <- grouped(@shown)} class="recipe-kind">
        <h3>{kind} <span class="muted-note">（{length(list)} 品）</span></h3>
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

      <%!-- 名簿の広さ。**足すだけ**の引き直しなので、下げると広がり、上げても減らない --%>
      <form :if={@roster} class="recipe-roster" phx-submit="reroster_recipes">
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

      <.recipe_modal :if={@recipe} recipe={@recipe} />
    </section>
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
  絞り込み。国と種類は一致、語は料理名と主な食材の部分一致（大文字小文字は区別しない）。
  """
  def filtered(recipes, filter) do
    country = blank(filter["country"])
    kind = blank(filter["kind"])
    q = filter["q"] |> blank() |> then(&(&1 && String.downcase(&1)))

    Enum.filter(recipes, fn recipe ->
      (is_nil(country) or recipe.country == country) and
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

  # 多い順（同じ数なら名前順）
  defp counts(recipes, key) do
    recipes
    |> Enum.map(key)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {name, n} -> {-n, name} end)
  end

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
