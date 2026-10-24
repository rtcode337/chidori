defmodule ChidoriWeb.RecentRuns do
  @moduledoc """
  **最近の回**（Chiezo の変更履歴を新しい順に）と、1 回ぶんの「足した・直した・消した」の見出し。
  趣味の収集の画面（記事の収集と本棚）と関連図の収集の画面で同じものを出す。
  """

  use Phoenix.Component

  alias Chidori.Jst

  @doc "最近の回の一言（足した・直した・消した数。失敗ならその理由）。"
  def run_state(%{status: "ok", added: 0, updated: 0, removed: 0}), do: "変化なし"

  def run_state(%{status: "ok"} = run),
    do: "足した #{run.added} ・直した #{run.updated} ・消した #{run.removed}"

  def run_state(%{error: error}), do: "失敗（#{error}）"

  @doc "最近の回が見た範囲（区画の数。区画を回らない回は空）。"
  def run_scope(%{visited: [_ | _] = visited, scope: scope}) when visited != scope,
    do: "区画 #{length(visited)} / #{length(scope)} つ"

  def run_scope(%{scope: [_ | _] = scope}), do: "区画 #{length(scope)} つ"
  def run_scope(_run), do: ""

  attr :runs, :list, required: true
  attr :collection, :string, required: true
  attr :reload, :string, required: true, doc: "読み直すイベントの名前"

  @doc """
  **最近の回**（自動で回った回も、依頼で走った回も）。依頼の結果は依頼ごとに回を引き当てるので、
  整理やざっと見るが何を直したのかはここで見る。依頼で走った回には印を付ける（同じ回が上の
  依頼の結果にも出る）。**どれも畳んで出す**（依頼の結果と同じ理由）。収集ごとに 1 つ
  （親の収集と、この収集から作る収集）。
  """
  def recent_runs(assigns) do
    ~H"""
    <section :if={@runs != []} class="request-results" aria-label="最近の回">
      <header class="request-results-head">
        <h3>最近の回</h3>
        <button type="button" phx-click={@reload}>読み直す</button>
      </header>
      <details :for={%{change: run, by_request: by_request} <- @runs} class="request-result">
        <summary>
          <span class="request-when">{Jst.format(run.at)}</span>
          <span class="request-scope">
            {run.sweep}{if run_scope(run) != "", do: "・#{run_scope(run)}", else: ""}
          </span>
          <span :if={by_request} class="run-by-request">依頼</span>
          <span class={[
            "request-state",
            run.status == "ok" && run.added + run.updated + run.removed > 0 && "has-result"
          ]}>
            {run_state(run)}
          </span>
        </summary>
        <p :if={run.status == "ok" and run.error != ""} class="muted-note">
          Chiezo の控え: {run.error}
        </p>
        <p class="muted-note">
          {if run.backend,
            do: "#{run.backend}#{if run.model, do: " / #{run.model}", else: ""}。",
            else: ""}見出しを押すと、直す前との違いが開きます。
        </p>
        <.change_lists change={run} collection={@collection} />
      </details>
    </section>
    """
  end

  @doc """
  1 回ぶんの「足した・直した・消した」の見出しの一覧。**依頼の結果と最近の回で
  同じものを出す**（見出しを押すと、直す前との違いがこの画面の上に開く。`ChidoriWeb.DocDiff`）。
  """
  attr :change, :map, required: true
  attr :collection, :string, required: true

  def change_lists(assigns) do
    ~H"""
    <div
      :for={
        {label, titles, count, class} <- [
          {"足した", @change.added_titles, @change.added, "is-added"},
          {"直した", @change.updated_titles, @change.updated, "is-updated"},
          {"消した", @change.removed_titles, @change.removed, "is-removed"}
        ]
      }
      :if={count > 0}
      class={["request-changes", class]}
    >
      <h4>{label}（{count} 件）</h4>
      <ul>
        <%!-- **押すと、Chidori の画面の上でその 1 件の変更が開く**（`ChidoriWeb.DocDiff`。
             Chiezo の管理画面へは飛ばさない） --%>
        <li :for={title <- titles}>
          <button
            type="button"
            class="doc-diff-link"
            phx-click="open"
            phx-target="#doc-diff"
            phx-value-collection={@collection}
            phx-value-title={title}
          >
            {title}
          </button>
        </li>
        <li :if={more_than_shown(count, titles) > 0} class="muted-note">
          ほか {more_than_shown(count, titles)} 件（Chiezo の控えは頭のほうだけ）
        </li>
      </ul>
    </div>
    """
  end

  @doc "見出しの一覧に出しきれなかった数（Chiezo の控えは頭のほうだけ）。"
  def more_than_shown(count, titles) when count > length(titles), do: count - length(titles)
  def more_than_shown(_count, _titles), do: 0
end
