defmodule Chidori.Relations.Marks do
  @moduledoc """
  関連図のノードに付けた「見た」印とメモの置き場。

  **利用者が書いたことは Chidori が持ちます。** 図そのものは Chiezo から読んでいて、
  読み直すたびに入れ替わりますが、ここに入るのは「この画家の展覧会へ行った」のような
  利用者ごとの事情なので、Chiezo には置きません（あちらは題材も好みも持たない側）。

  **データ収集の Pi-hole のドメインも、同じ置き場を使います**（view は
  `Chidori.Datasets.Pihole.mark_view/0`、ノードの名前がドメイン）。見たかどうか・いつ・
  ひとこと、という形が同じで、表を分ける理由が無いため。

  **暫定の形です。** いまは 1 ノードに 1 件で、見たかどうか・いつ・ひとこと、
  だけを持ちます。同じ画家を何度も見に行く記録が要るようになったら、
  この表を親にして展覧会ごとの子を足す形へ広げられます。
  """

  import Ecto.Query

  alias Chidori.Relations.Mark
  alias Chidori.Repo

  @doc "その図に付いている印を、ノード名で引ける形で返します。"
  def for_view(view) when is_binary(view) do
    Mark
    |> where([m], m.view == ^view)
    |> Repo.all()
    |> Map.new(&{&1.node_name, &1})
  end

  @doc "1 ノードぶん。まだ付いていなければ `nil`。"
  def get(view, node_name) when is_binary(view) and is_binary(node_name) do
    Repo.get_by(Mark, view: view, node_name: node_name)
  end

  @doc """
  印を書き込みます。**何も書かれていない印は残さず消します** ——
  印も日付もメモも無い行が残っていると、図の上で「見た」と見分けが付きません。

  返すのは `{:ok, mark | nil}`（消したときは `nil`）。
  """
  def put(view, node_name, attrs) when is_binary(view) and is_binary(node_name) do
    mark = get(view, node_name) || %Mark{}
    attrs = Map.merge(attrs, %{"view" => view, "node_name" => node_name})

    changeset = Mark.changeset(mark, attrs)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, applied} ->
        if Mark.blank?(applied), do: delete(mark), else: save(changeset)

      {:error, _changeset} = error ->
        error
    end
  end

  defp save(changeset) do
    case Repo.insert_or_update(changeset) do
      {:ok, mark} -> {:ok, mark}
      {:error, _changeset} = error -> error
    end
  end

  defp delete(%Mark{id: nil}), do: {:ok, nil}

  defp delete(%Mark{} = mark) do
    case Repo.delete(mark) do
      {:ok, _mark} -> {:ok, nil}
      {:error, _changeset} = error -> error
    end
  end
end
