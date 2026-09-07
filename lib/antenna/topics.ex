defmodule Antenna.Topics do
  @moduledoc """
  話題(アンテナ)ごとの設定。

  いまは「ニュース」1 つだが、他の話題を順次足していく前提の作りにしてある。
  1 つぶんを環境変数で持つと、2 つ目を足すときに置き場ごと作り直すことになる。

  **相手は 2 つ持つ**(集める相手と選ぶ相手)。役割が違うので、速さと質の釣り合いも
  別に決めたい —— 集めるのは web を歩く仕事、選ぶのは溜まったものを読む仕事。
  どちらも未指定なら Chiezo の既定にまかせる。
  """

  import Ecto.Query

  alias Antenna.Repo
  alias Antenna.Topics.Topic

  @doc "並びは名前順。画面と一覧はこの順に出す。"
  def list do
    Repo.all(from(t in Topic, order_by: t.name))
  end

  def get!(id), do: Repo.get!(Topic, id)

  def get_by_collection(collection), do: Repo.get_by(Topic, collection: collection)

  def create(attrs) do
    %Topic{} |> Topic.changeset(attrs) |> Repo.insert()
  end

  def update(%Topic{} = topic, attrs) do
    topic |> Topic.changeset(attrs) |> Repo.update()
  end

  def delete(%Topic{} = topic), do: Repo.delete(topic)

  def change(%Topic{} = topic, attrs \\ %{}), do: Topic.changeset(topic, attrs)

  @doc """
  まだ 1 つも無ければ、ニュースの話題を置く。

  **空の画面から始めさせない** —— 何を設定すればよいかが分からないと、
  最初の 1 つを作れない。消したければ普通に削除できる。
  """
  def ensure_default do
    if Repo.aggregate(Topic, :count) == 0 do
      create(%{
        name: "ニュース",
        collection: "antenna_news",
        interest: "暮らし・社会・経済への影響が大きいこと"
      })
    else
      :ok
    end
  end
end
