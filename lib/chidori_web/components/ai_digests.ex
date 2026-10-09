defmodule ChidoriWeb.AiDigests do
  @moduledoc """
  書き手ごとの要約（`Chidori.News.AiDigests`）を並べる部品。トップと最新情報の画面で同じもの。

  **1 人ぶんずつ畳んで並べる**（最初の 1 人だけ開いておく）。全員の全文を広げると、
  1 本が数千字あるので、2 人目から先が画面のずっと下になる。
  """
  use Phoenix.Component

  attr :digests, :any, required: true, doc: "`nil` / `:loading` / `{:ok, list}` / `{:error, _}`"
  attr :label, :string, default: nil
  attr :id_prefix, :string, default: "ai-digest"

  def ai_digests(assigns) do
    ~H"""
    <p :if={@digests in [nil, :loading]} class="muted-note">読み込んでいます…</p>
    <p :if={match?({:error, _}, @digests)} class="muted-note">要約を読めませんでした。</p>
    <p :if={@digests == {:ok, []}} class="muted-note">まだ要約がありません。</p>
    <div :if={match?({:ok, [_ | _]}, @digests)} class="ai-digests">
      <details
        :for={{digest, index} <- Enum.with_index(elem(@digests, 1))}
        class="ai-digest"
        open={index == 0}
      >
        <summary>
          <span class="ai-digest-author">{digest.author}</span>
          <span class="ai-digest-at">{digest.at}</span>
        </summary>
        <ChidoriWeb.Report.report
          title={digest.title}
          at={digest.at}
          body={digest.body}
          label={@label}
          id_prefix={"#{@id_prefix}-#{index}"}
        />
      </details>
    </div>
    """
  end
end
