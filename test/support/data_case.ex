defmodule Chidori.DataCase do
  @moduledoc """
  DB を触るテストの土台。

  **sandbox で包む**ので、テストが書いた行はそのテストが終わると消える。
  前のテストの行を引きずると、単体では通るのに並べると落ちる、という
  追いにくい壊れ方をする。
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Chidori.DataCase
      import Ecto.Changeset
      import Ecto.Query

      alias Chidori.Repo
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Chidori.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    # 利用者が書いたことの置き場（`Chidori.DataStore`）は 1 つのプロセスが持つので、
    # 並べて走らないテストのたびに空にする。並べて走るテストは置き場に書かないこと
    unless tags[:async], do: Chidori.DataStore.reset()
  end

  @doc "変更セットのエラーを、項目名 → メッセージの並びにする。"
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
