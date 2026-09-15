defmodule Tazuna.Notify do
  @moduledoc """
  まとめを知らせるところ。**同じものを二度知らせない**のがここの仕事です。

  まとめは Chiezo に溜まっていて、tazuna は時々読みに行くだけです ——
  **読み直すたびに同じまとめが返る**ので、何を知らせたかを覚えていないと、
  読むたびに通知が飛びます。覚える先は DB です（メモリだと、立ち上げ直した拍子に
  前のまとめをもう一度知らせることになります）。

  **宛先を変えたら、変えた先へは改めて届きます。** 記録の鍵に宛先も入れてあるので、
  引っ越した先には「もう知らせた」と黙りません。
  """

  import Ecto.Query

  alias Tazuna.News
  alias Tazuna.Notify.Notice
  alias Tazuna.Ntfy
  alias Tazuna.Repo

  require Logger

  @doc """
  その話題のいちばん新しいまとめを知らせます。

  **知らせないときも理由を返します** —— 無言で何もしないと、設定を間違えているのか
  まとめがまだ無いのかを、後から見ている人が区別できません。
  """
  def deliver_latest(%{collection: collection}, %{digests: digests}) do
    case List.first(digests) do
      nil -> {:ok, :nothing_to_send}
      digest -> deliver(collection, digest)
    end
  end

  def deliver_latest(_topic, _news), do: {:ok, :nothing_to_send}

  @doc """
  まとめ 1 件を知らせます。**既に知らせたものは送りません**。
  """
  def deliver(collection, digest) do
    with {:ok, {_base, ntfy_topic}} <- Ntfy.ready(collection),
         false <- sent?(collection, digest.title, ntfy_topic) do
      send_and_record(collection, ntfy_topic, digest)
    else
      # 送れない理由（宛先が未設定など）はそのまま返す。押した人にも読めるように
      {:error, reason} -> {:error, reason}
      true -> {:ok, :already_sent}
    end
  end

  defp send_and_record(collection, ntfy_topic, digest) do
    case Ntfy.notify(collection, digest.title, News.digest_text(digest),
           click: click_url(collection)
         ) do
      :ok ->
        record(collection, digest.title, ntfy_topic)
        {:ok, :sent}

      {:error, reason} ->
        # **届かなかったものは記録しない。** 記録すると、次に読み直したときに
        # 「もう知らせた」と黙って飛ばされ、そのまとめは永遠に届かない
        Logger.warning("ntfy へ知らせられなかった（#{collection}）: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "知らせたことがあるか。"
  def sent?(collection, key, ntfy_topic) do
    Repo.exists?(
      from(n in Notice,
        where: n.collection == ^collection and n.key == ^key and n.topic == ^(ntfy_topic || "")
      )
    )
  end

  @doc """
  知らせたことを残します。**同時に 2 つ走っても 1 件**（一意制約に任せます）。
  """
  def record(collection, key, ntfy_topic) do
    %Notice{}
    |> Notice.changeset(%{collection: collection, key: key, topic: ntfy_topic || ""})
    |> Repo.insert(on_conflict: :nothing)
  end

  # 押したときに開く先。**通知の 1 行だけでは足りない**ので、続きを読む場所を添える
  defp click_url(collection) do
    TazunaWeb.Endpoint.url() <> "/news?view=" <> URI.encode_www_form(collection)
  end
end
