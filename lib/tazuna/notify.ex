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
  def deliver_latest(collection, %{digests: digests}, opts \\ []) do
    case List.first(digests) do
      nil -> {:ok, :nothing_to_send}
      digest -> deliver(collection, digest, opts)
    end
  end

  @doc """
  まとめ 1 件を知らせます。

  **押されたときは、知らせ済みでも送ります**（`force: true`）。押すのは意思表示
  なので、そこで黙られると「壊れているのか、もう送ったのか」が分かりません ——
  送ったことは画面に出るので、二度目が要らないかは押す人が決められます。
  """
  def deliver(collection, digest, opts \\ []) do
    with {:ok, {_base, ntfy_topic}} <- Ntfy.ready(collection),
         false <- opts[:force] != true and sent?(collection, digest.title, ntfy_topic) do
      send_and_record(collection, ntfy_topic, digest)
    else
      # 送れない理由（宛先が未設定など）はそのまま返す。押した人にも読めるように
      {:error, reason} -> {:error, reason}
      true -> {:ok, :already_sent}
    end
  end

  @doc """
  その話題へ最後に知らせた時刻。**押した結果がここに出ます**。
  """
  def last_sent_at(collection) do
    Repo.one(
      from(n in Notice,
        where: n.collection == ^collection,
        # **送った時刻で見る**（足した時刻ではない）—— 二度目は行が増えないので、
        # 足した時刻だと押しても画面が動かない
        order_by: [desc: n.updated_at],
        limit: 1,
        select: n.updated_at
      )
    )
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

  **二度目は時刻だけ進めます。** 押されたときは知らせ済みでも送るので、
  行を足さずに黙ると、**画面の「最後に知らせた」が送った瞬間から古いまま**になります。
  """
  def record(collection, key, ntfy_topic) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %Notice{}
    |> Notice.changeset(%{collection: collection, key: key, topic: ntfy_topic || ""})
    |> Repo.insert(
      on_conflict: [set: [updated_at: now]],
      conflict_target: [:collection, :key, :topic]
    )
  end

  # 押したときに開く先。**通知の 1 行だけでは足りない**ので、続きを読む場所を添える
  defp click_url(collection) do
    TazunaWeb.Endpoint.url() <> "/news?view=" <> URI.encode_www_form(collection)
  end
end
