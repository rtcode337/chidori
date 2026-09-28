defmodule Tazuna.News.StockResearch do
  @moduledoc """
  銘柄調査。**調べる銘柄は外のアプリ（売買提案のアプリ）が決めて渡してきます**（`request/2`）。
  tazuna はその一覧を Chiezo の巡回「情報収集」へ、その回だけの頼みごととして渡して
  走らせ、調べた結果は Chiezo に溜まります（売買提案のアプリ は Chiezo から読む）。

  ## なぜ時計を持たないか

  どの銘柄を調べるかは、保有と値動きと決算の予定で決まり、**それを知っているのは
  売買提案のアプリ だけ**です。Chiezo の時計で回すと、何を調べればよいか分からない回が走ります。
  だから巡回は時計を持たず（`on_demand`）、売買提案のアプリ が頼んだときだけ動きます。
  頼み方は Chiezo の割り込み（`focus`）で、**一覧は依頼文に保存しません** ——
  その回だけの頼みごととして渡るので、定義は育てたまま変わりません。

  ## 1 件の形

  **1 件 = 1 銘柄 × 1 日**（見出し `7203 トヨタ自動車 2026-09-28`）。同じ銘柄を
  次の日に調べれば別の 1 件になり、売買提案のアプリ は日付をまたいで読み比べられます。
  **調べる AI は 1 つで、結果は共有**です（参加者ごとに別々に調べていた頃は、
  同じ銘柄を何度も調べて枠を使っていた）。

  - tags: `銘柄:<コード>`・`調査日:<YYYY-MM-DD>`・`材料:あり/なし`・
    `値動き:個別/地合い/不明`
  - body: 人が読む要約を先に、**売買提案のアプリ が読む JSON を最後に**置きます（```json の塊）。
    Chiezo の脇書きは入れ子を運べないので、記事の並びは本文に持たせる
  """

  alias Tazuna.Chiezo

  @code_tag "銘柄"
  @date_tag "調査日"
  @material_tag "材料"
  @move_tag "値動き"

  # 1 回に頼む銘柄の数の上限。**1 回の答えに収まる数**（1 銘柄あたり記事を数本と
  # 検証を返させるので、多すぎると途中で打ち切られる）
  @max_targets 20

  @doc "銘柄コードのタグの頭。"
  def code_tag, do: @code_tag

  @doc "調査日のタグの頭。"
  def date_tag, do: @date_tag

  @doc "1 回に頼める銘柄の数の上限。"
  def max_targets, do: @max_targets

  @doc """
  巡回（`Tazuna.News.sweeps/1` がこちらを使う）。**時計を持たない情報収集の 1 本だけ**。
  """
  def sweeps(topic) do
    [
      %{
        name: Tazuna.SweepNames.survey(),
        on_demand: true,
        prompt: prompt(topic)
      }
    ]
  end

  @doc """
  情報収集の回の依頼文。**調べる銘柄は、この文の後ろに頼みごととして付いてきます**
  （Chiezo の割り込みの `note`）。
  """
  def prompt(topic) do
    """
    **下に頼みごととして付いてくる銘柄を 1 つずつ調べて**、1 銘柄につき 1 件を返してください。
    今日は {now} です（日本時間）。

    何を調べるかは次のとおりです。
    #{Map.get(topic, :interest, "")}

    1 銘柄ごとに、次のことを当たってください。

    - **直近 1 週間ほどの、株価に効きそうな材料**（決算・業績修正・受注・提携・
      規制・訴訟・格付けの変更・大株主の動きなど）。公式の発表（適時開示・IR）を先に
      当たり、報道で補ってください
    - **値動きの理由**（頼みごとに騰落率が書いてあるとき）。その銘柄だけの材料で
      動いたのか（個別）、市場全体や業種の流れで動いたのか（地合い）。
      **言われている理由は確かめてから書いてください** —— 出どころで確かめられたかを
      JSON の verified に入れます

    **材料が見つからなければ「材料:なし」で返してください**（空振りも 1 件です ——
    返さないと、調べたのに何も無かったのか、調べていないのかが分かりません）。
    **確信の持てないことは書かないでください。** 推測で理由を作らないでください。

    **見出しの形は必ず下のとおりにしてください** —— 同じ銘柄を同じ日にもう一度
    調べたときは、同じ見出しで返せば今日の 1 件が書き直されます（見出しが重複の鍵です）。

    1 件ごとに次の形で返してください。
    - title: "<コード> <銘柄名> <今日の日付 YYYY-MM-DD>"（例: "7203 トヨタ自動車 2026-09-28"）
    - url: いちばん確かな出どころの URL（無ければ会社の IR のページ）
    - tags:
      - "#{@code_tag}:<コード>"（頼みごとに書いてあるコードのまま）
      - "#{@date_tag}:<今日の日付 YYYY-MM-DD>"
      - "#{@material_tag}:あり" / "#{@material_tag}:なし"
      - "#{@move_tag}:個別" / "#{@move_tag}:地合い" / "#{@move_tag}:不明"
    - body: 次の順に書いてください
      1. 要約を 2〜4 文（人が読みます。材料が無ければ「目立った材料は見当たらない」と書く）
      2. 最後に、次の JSON を ```json と ``` で囲んで 1 つ（プログラムが読みます）

    ```json
    {"summary": "要約と同じ文",
     "items": [{"headline": "見出し", "summary": "1〜2 文", "url": "記事の URL",
                "published_at": "YYYY-MM-DD", "category": "決算/業績/受注/提携/規制/その他"}],
     "move_claims": [{"claim": "言われている値動きの理由", "source": "出どころの URL",
                      "verified": true}]}
    ```

    **頼みごとに無い銘柄は返さないでください。**
    """
  end

  @doc """
  売買提案のアプリ から届いた一覧で、情報収集の回を 1 回走らせます。

  `targets` は `%{"code" => "7203", "name" => "トヨタ自動車", "reason" => "…",
  "move_pct" => -3.2}` の並び（`reason` と `move_pct` は無くてよい）。
  **上限を超えたら断ります**（黙って切ると、渡したつもりの銘柄が調べられない）。
  """
  def request(collection, targets) when is_list(targets) do
    with {:ok, targets} <- validate(targets),
         base when is_binary(base) <-
           Tazuna.News.chiezo_base_url() || {:error, :chiezo_not_configured} do
      Chiezo.focus(base, collection, note(targets), [], Tazuna.SweepNames.survey())
    end
  end

  def request(_collection, _targets), do: {:error, :bad_targets}

  @doc false
  def validate([]), do: {:error, :no_targets}

  def validate(targets) when length(targets) > @max_targets, do: {:error, :too_many_targets}

  def validate(targets) do
    cleaned =
      for target <- targets, is_map(target) do
        %{
          code: target |> Map.get("code") |> clean(),
          name: target |> Map.get("name") |> clean(),
          reason: target |> Map.get("reason") |> clean(),
          move_pct: number(Map.get(target, "move_pct"))
        }
      end

    # **コードは証券コードの形だけ**（4 桁。新しいコードは英字を含む）。依頼文に
    # そのまま入るので、形の分からないものを通さない
    if cleaned != [] and length(cleaned) == length(targets) and
         Enum.all?(cleaned, &(&1.code =~ ~r/\A[0-9A-Z]{4}\z/ and &1.name != "")),
       do: {:ok, cleaned},
       else: {:error, :bad_targets}
  end

  @doc "頼みごとの文（割り込みの note）。1 行 1 銘柄。"
  def note(targets) do
    lines =
      Enum.map_join(targets, "\n", fn target ->
        [
          "- #{target.code} #{target.name}",
          target.move_pct && "（騰落率 #{format_pct(target.move_pct)}）",
          target.reason != "" && "：#{target.reason}"
        ]
        |> Enum.filter(&is_binary/1)
        |> Enum.join()
      end)

    "次の #{length(targets)} 銘柄を調べてください。\n" <> lines
  end

  defp clean(value) when is_binary(value),
    do: value |> String.replace(~r/[\r\n]+/, " ") |> String.trim() |> String.slice(0, 80)

  defp clean(_value), do: ""

  defp number(value) when is_number(value), do: value
  defp number(_value), do: nil

  defp format_pct(value) do
    sign = if value > 0, do: "+", else: ""
    sign <> :erlang.float_to_binary(value / 1, decimals: 1) <> "%"
  end
end
