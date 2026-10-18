defmodule Chidori.Relations.CarrySetting do
  @moduledoc """
  最新情報の映画を映画の図へ引き継ぐ時計（`Chidori.Relations.FilmCarry`）の設定と、
  前回頼んだ記録（表 `film_carry_settings`。1 行だけ）。

  **頼む時刻は Chidori ごとに決め、既定は空（頼まない）です。** 時計は Chidori の中に
  あるので、本番とテストの 2 つを立てていると、どちらも同じ割り込みを頼みます。
  時刻を書いた Chidori だけが頼むようにして、二重に頼まない（要約の時刻と同じ書き方。
  `Chidori.Notify.Setting.times_of/1`）。

  **前回の記録も DB に持ちます。** プロセスの中に持つと、再起動のたびに消えて
  「いつ頼んだのか」が画面から読めない。
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Chidori.Notify.Setting
  alias Chidori.Repo

  # 1 回に頼む数。**AI が 1 回で返し切れる数**に抑える
  @batch_choices [5, 10, 20, 30, 50]

  # 頼めた回の結果の文（`ok?/1` はこれで見分ける）
  @asked "頼みました"
  @nothing "引き継ぐものはありませんでした"

  schema "film_carry_settings" do
    field(:run_at, :string, default: "")
    field(:batch, :integer, default: 20)
    field(:last_at, :utc_datetime)
    field(:last_result, :string)
    field(:last_titles, {:array, :string}, default: [])
    field(:last_by, :string)

    # 時計が最後に頼みに行った時刻と、済んだか（画面から足した 1 回とは分けて持つ ——
    # 混ぜると、画面で 1 本足しただけでその日の時計の回が飛ぶ）
    field(:clock_at, :utc_datetime)
    field(:clock_ok, :boolean, default: false)

    # 作品ごとに、図へ足すよう頼んだ回数（見出し → 回数）。**何度頼んでも載らない作品を
    # 時計から外すため** —— 外さないと、その作品が毎回の枠の頭を占め続け、後ろの作品が
    # いつまでも頼まれない（しかも頼むたびに AI を 1 回使う）
    field(:attempts, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @doc "選べる 1 回の数。"
  def batch_choices, do: @batch_choices

  @doc "今の設定と前回の記録（まだ無ければ既定の値）。"
  def get do
    Repo.one(__MODULE__) || %__MODULE__{}
  rescue
    # 表がまだ無い（マイグレーションの前）ときも画面は出す
    _error in [Postgrex.Error, DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      %__MODULE__{}
  end

  @doc "頼む時刻（JST の `{時, 分}` を早い順に）。空なら頼まない。"
  def times(%__MODULE__{run_at: text}), do: Setting.times_of(text || "")

  @doc "時刻と 1 回の数を書き換えます。**読めない時刻と選べない数は断ります**。"
  def put(attrs) do
    get()
    |> cast(attrs, [:run_at, :batch])
    |> update_change(:run_at, &Setting.normalize_times/1)
    |> validate_change(:run_at, fn :run_at, text ->
      if Setting.bad_times(text) == [],
        do: [],
        else: [run_at: "時刻は 24 時間制で書いてください（例: 04:00,16:00）"]
    end)
    |> validate_inclusion(:batch, @batch_choices)
    |> Repo.insert_or_update()
  end

  @doc """
  頼んだ結果を残します。`by` は `"時計"` か `"画面"`、`result` は `:ok`・`:nothing`
  （まだのものが無かった）・`{:error, 理由の文}`。
  """
  def record(by, titles, result) do
    text =
      case result do
        :ok -> @asked
        :nothing -> @nothing
        {:error, reason} -> "頼めませんでした: " <> reason
      end

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    done? = result in [:ok, :nothing]
    clock = if by == "時計", do: [clock_at: now, clock_ok: done?], else: []

    get()
    |> change([last_at: now, last_result: text, last_titles: titles, last_by: by] ++ clock)
    |> Repo.insert_or_update()
  end

  @doc "時計が頼むのをやめるまでの回数（これだけ頼んでも載らない作品は、人が頼み直すまで頼まない）。"
  def max_attempts, do: 3

  @doc "その作品を頼んだ回数。"
  def attempts(%__MODULE__{attempts: attempts}, title) when is_map(attempts),
    do: Map.get(attempts, title, 0)

  def attempts(_setting, _title), do: 0

  @doc """
  頼めた作品の回数を 1 つ増やします。**載ったもの（引き継ぎ済み）は消します**（`carried`）——
  回数の表が、図に載った作品の分だけ太り続けないように。
  """
  def count_attempts(titles, carried \\ MapSet.new()) do
    setting = get()

    attempts =
      (setting.attempts || %{})
      |> Map.reject(fn {title, _n} -> MapSet.member?(carried, title) end)
      |> then(
        &Enum.reduce(titles, &1, fn title, acc -> Map.update(acc, title, 1, fn n -> n + 1 end) end)
      )

    setting |> change(attempts: attempts) |> Repo.insert_or_update()
  end

  @doc "前回が済んでいるか（頼めた・頼むものが無かった）。"
  def ok?(%__MODULE__{last_result: result}) when result in [@asked, @nothing], do: true
  def ok?(_setting), do: false
end
