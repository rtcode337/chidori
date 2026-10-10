defmodule Chidori.WebPush.Key do
  @moduledoc """
  送り手の鍵（VAPID。P-256）。**行は 1 つだけ**で、最初に要ったときに作ります。

  **手で用意させません。** 環境変数で渡す形にすると、鍵を作る手順と置き場所を
  運用する人が覚えている必要があり、イメージに焼き込めば誰でも読めます。
  **作り直しもしません** —— 鍵が替わると、登録済みの端末はすべて受け取れなくなり、
  端末ごとに登録し直すことになります（DB を作り直したときも同じ）。
  """

  use Ecto.Schema

  import Ecto.Query

  alias Chidori.Repo

  schema "web_push_keys" do
    # 非圧縮形の公開鍵（65 バイト）と、秘密鍵（32 バイト）
    field(:public_key, :binary)
    field(:private_key, :binary, redact: true)

    timestamps(type: :utc_datetime)
  end

  @doc """
  いまの鍵。**無ければ作って置きます**。

  同時に 2 つ作られても、読むのは最初の行だけなので食い違いません。
  """
  def get do
    case first() do
      %__MODULE__{} = key ->
        key

      nil ->
        {public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)
        Repo.insert!(%__MODULE__{public_key: public_key, private_key: private_key})
        first()
    end
  end

  defp first, do: Repo.one(from(k in __MODULE__, order_by: [asc: k.id], limit: 1))
end
