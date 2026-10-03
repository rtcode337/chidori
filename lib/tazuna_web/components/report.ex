defmodule TazunaWeb.Report do
  @moduledoc """
  まとめを、読み物のレポートとして描きます。

  **溜まったものを並べる画面とは別のものです。** 一覧は 1 件ずつの索引で、
  こちらは「その期間に何が起きたか」を通しで読ませる場所です —— 要旨・目次・
  章・表・出典を持たせてあるのはそのためで、拾い読みでも通読でも読めるようにしています。

  **描くのは読み分けた一片だけです**（`Tazuna.News.Report`）。本文を書くのは AI なので、
  素の HTML を渡せる道は作りません —— 段落・箇条書き・表・注記・出典に割ってから、
  1 片ずつ描きます。

  **出典は記事の見出しでリンクにします。** 裸の URL のままだと、押す前にどこへ
  行くのか読めません。見出しは、まとめが書いたもの → 溜まっている記事のもの、の順で
  使います。どちらも無ければ URL のまま出します（AI が上に無いものを書いたときに、
  黙って消さないため）。

  **絵は集めた記事から借ります。** 配信元がフィードで配っているぶんだけで、
  まとめの側は絵を持ちません —— 出典の記事を引き直して、その章に 1 枚だけ添えます
  （章ごとに何枚も並べると、読み物ではなく一覧に見えます）。
  """

  use TazunaWeb, :html

  alias Tazuna.News.Report

  attr :title, :string, required: true
  attr :at, :string, default: nil
  attr :body, :string, default: ""
  attr :label, :string, default: nil
  attr :articles, :list, default: []
  attr :cited, :map, default: %{}

  # 章の目印（目次のリンク先）の頭。**同じページに 2 つ描くときは変える** ——
  # 同じ id が 2 つあると、目次が片方にしか飛ばず、LiveView も描き直す先を取り違える
  attr :id_prefix, :string, default: "report"

  # **頭だけを描く**（見出し・要旨・目次）。ページの上の窓がこれで、章と出典は
  # 全画面で読む。目次の項目は、押すと全画面でその章から開く（`open_event`）
  attr :intro_only, :boolean, default: false
  attr :open_event, :string, default: nil
  # どの並びのまとめか（全画面で開くときに渡す。`main` / `interest`）
  attr :open_kind, :string, default: nil

  # **頭に絵を並べる**（映画の要約。おすすめの作品のポスターを、要旨より先に見せる）。
  # 並べるのは出典の順で、絵を持つものの最初の数枚
  attr :hero, :boolean, default: false

  @doc """
  まとめ 1 件を、レポートとして描きます。

  出典に見出しと絵を添えるために、記事を 2 つの道から受け取ります ——
  `cited` は**まとめが引いた記事を引き直したもの**（出典の URL が鍵）、
  `articles` は画面に並んでいる直近のぶんです。**引き直したほうを先に使います**。
  """
  def report(assigns) do
    document = Report.document(assigns.body || "")

    known =
      assigns.articles
      |> Map.new(&{&1.url, &1})
      |> Map.merge(assigns.cited || %{})
      |> without_shared_images()

    sections =
      document.sections
      |> Enum.with_index(1)
      |> Enum.map(fn {section, index} ->
        section
        |> Map.put(:index, index)
        |> Map.put(:figure, figure_of(section.blocks, known))
      end)

    sources = Report.sources(document)

    assigns =
      assign(assigns,
        summary: document.summary,
        sections: sections,
        sources: sources,
        known: known,
        hero_figures: if(assigns.hero, do: hero_figures(sources, known), else: [])
      )

    ~H"""
    <article class="report">
      <header class="report-head">
        <p class="report-kicker">{@label || "レポート"}</p>
        <h2>{@title}</h2>
        <p :if={@at} class="report-at">{@at}</p>
      </header>

      <%!-- おすすめの絵（`hero`）。**要旨より先に**、出典の順で数枚 --%>
      <ul :if={@hero_figures != []} class="report-hero" aria-label="おすすめ">
        <li :for={figure <- @hero_figures}>
          <a href={figure.url} target="_blank" rel="noreferrer" title={figure.label}>
            <img src={figure.image} alt="" loading="lazy" />
            <span>{figure.label}</span>
          </a>
        </li>
      </ul>

      <%!-- 要旨。通知に流れるのもここ（同じ文を、出す場所に合わせて使い分ける） --%>
      <section :if={@summary != []} class="report-summary" aria-label="要旨">
        <p class="report-summary-label">要旨</p>
        <.blocks blocks={@summary} known={@known} />
      </section>

      <%!-- 目次。章が 2 つ以上あるときだけ（1 つしかない目次は、ただの重複） --%>
      <nav :if={length(@sections) > 1} class="report-toc" aria-label="目次">
        <ol>
          <li :for={section <- @sections}>
            <a
              :if={@open_event}
              href={"#digest-viewer-s#{section.index}"}
              phx-click={@open_event}
              phx-value-index="0"
              phx-value-kind={@open_kind}
              phx-value-section={section.index}
            >
              {section.title}
            </a>
            <a :if={!@open_event} href={"##{@id_prefix}-s#{section.index}"}>{section.title}</a>
          </li>
        </ol>
      </nav>

      <section
        :for={section <- @sections}
        :if={!@intro_only}
        id={"#{@id_prefix}-s#{section.index}"}
        class="report-section"
      >
        <h3><span class="report-number">{section.index}</span>{section.title}</h3>

        <%!-- 絵は本文の脇に置く。上に置くと、読む前に大きな絵が挟まって章が切れる --%>
        <figure :if={section.figure} class="report-figure">
          <a href={section.figure.url} target="_blank" rel="noreferrer">
            <img src={section.figure.image} alt="" loading="lazy" />
          </a>
        </figure>

        <.blocks blocks={section.blocks} known={@known} />
      </section>

      <%!-- 出典一覧。章ごとの出典は読んだ流れで押すもので、こちらは後から
           「どこを見て書いたのか」をまとめて確かめるためのもの --%>
      <div :if={@sources != [] and !@intro_only} class="report-refs">
        <p class="report-refs-label">出典</p>
        <ol>
          <li :for={source <- @sources}>
            <a href={source.url} target="_blank" rel="noreferrer">
              {label_of(source, @known)}
            </a>
            <span class="report-ref-host">{host(source.url)}</span>
          </li>
        </ol>
      </div>
    </article>
    """
  end

  attr :blocks, :list, required: true
  attr :known, :map, default: %{}

  @doc false
  def blocks(assigns) do
    ~H"""
    <%= for block <- @blocks do %>
      <%= case block do %>
        <% {:paragraph, parts} -> %>
          <p><.parts parts={parts} /></p>
        <% {:list, items} -> %>
          <ul class="report-list">
            <li :for={item <- items}><.parts parts={item} /></li>
          </ul>
        <% {:note, parts} -> %>
          <p class="report-note"><.parts parts={parts} /></p>
        <% {:table, header, rows} -> %>
          <div class="report-table">
            <table>
              <thead>
                <tr>
                  <th :for={cell <- header}><.parts parts={cell} /></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- rows}>
                  <td :for={cell <- row}><.parts parts={cell} /></td>
                </tr>
              </tbody>
            </table>
          </div>
        <% {:source_note, text} -> %>
          <p class="digest-source">{text}</p>
        <% {:source, url, label} -> %>
          <p class="digest-source">
            出典:
            <a href={url} target="_blank" rel="noreferrer">
              {label_of(%{url: url, label: label}, @known)}
            </a>
          </p>
      <% end %>
    <% end %>
    """
  end

  attr :parts, :list, required: true

  @doc false
  # 行の中の一片。改行も空白も入れない —— 読点の前で折れると、文の途中に
  # 隙間が空いて出る
  def parts(assigns) do
    ~H"""
    <%= for part <- @parts do %>
      <%= case part do %>
        <% {:text, text} -> %>
          {text}
        <% {:strong, text} -> %>
          <strong>{text}</strong>
        <% {:link, url, label} -> %>
          <a href={url} target="_blank" rel="noreferrer">{label}</a>
      <% end %>
    <% end %>
    """
  end

  @doc false
  # 出典に出す文字。まとめが書いた見出し、溜まっている記事の見出し、URL の順に使う
  def label_of(%{url: url, label: label}, known) do
    cond do
      is_binary(label) and label != "" -> label
      match?(%{title: title} when is_binary(title), known[url]) -> known[url].title
      true -> url
    end
  end

  # 頭に並べる絵の数
  @hero_count 4

  @doc false
  # 頭に並べる絵。出典の順に、絵を持つものを #{@hero_count} 枚まで（同じ絵は 1 度だけ）
  def hero_figures(sources, known) do
    sources
    |> Enum.flat_map(fn %{url: url} = source ->
      case known[url] do
        %{image: image} when is_binary(image) and image != "" ->
          [%{url: url, image: image, label: label_of(source, known)}]

        _article ->
          []
      end
    end)
    |> Enum.uniq_by(& &1.image)
    |> Enum.take(@hero_count)
  end

  # 何件もの記事が同じ絵を指していたら、それは記事の絵ではなく配信元の共通の絵
  # （ロゴや既定の OGP 画像）。添えても何の話か分からないので外す
  @shared_image_min 3

  @doc false
  def without_shared_images(known) do
    shared =
      known
      |> Map.values()
      |> Enum.flat_map(fn
        %{image: image} when is_binary(image) and image != "" -> [image]
        _article -> []
      end)
      |> Enum.frequencies()
      |> Enum.filter(fn {_image, count} -> count >= @shared_image_min end)
      |> MapSet.new(&elem(&1, 0))

    if MapSet.size(shared) == 0 do
      known
    else
      Map.new(known, fn
        {url, %{image: image} = article} ->
          {url, if(MapSet.member?(shared, image), do: %{article | image: nil}, else: article)}

        other ->
          other
      end)
    end
  end

  @doc false
  # その章に添える絵。章が引いた出典のうち、絵を持つ記事の最初の 1 件
  def figure_of(blocks, known) do
    Enum.find_value(blocks, fn
      {:source, url, _label} ->
        case known[url] do
          %{image: image} when is_binary(image) and image != "" -> %{url: url, image: image}
          _article -> nil
        end

      _block ->
        nil
    end)
  end

  @doc false
  # 出典一覧に添える配信元。URL をそのまま出さない —— 長い URL が並ぶと、
  # 見出しのほうが読めなくなる
  def host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> String.trim_leading(host, "www.")
      _uri -> ""
    end
  end
end
