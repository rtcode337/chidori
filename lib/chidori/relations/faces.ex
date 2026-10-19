defmodule Chidori.Relations.Faces do
  @moduledoc """
  関連図の顔写真。**1 人 1 回だけ**取りに行き、写しを DB（`face_thumbs`）に持って、
  あとは Chidori が配ります（`/faces/:id`）。

  **写真の置き場に負荷をかけないための形です。**

  - 見る人のブラウザに Wikimedia を直に引かせない。数千人の図を開くたびに、見る人の
    数だけ写真が引かれることになる
  - **Chidori からも Wikimedia へは出ない。** Chiezo に縮小版を作らせ（`POST /v1/thumbs`。
    Chiezo は同じ絵を 1 度しか取らない）、その写しを受け取る —— 外への通信先を Chiezo だけにする
  - 頼むのは**小さな縮小版**（横 120px。Commons の決まった幅で、置き場の写しが当たる）だけ。
    原寸は引かない
  - **1 枚ずつ間を空けて**頼む（`@interval_ms`）
  - **取れなかったことも残す**（`missing`）。無いものを取りに行き続けない

  写真の出どころは記事の画像（Chiezo の jawiki の `extra.image`。名簿を引くときに運ぶ）。
  **Commons の写真だけ**を使います —— 日本語版にだけある画像はライセンスの扱いが
  別なので取らない。ライセンスは写真ごとに違うので、押したときに Commons の
  ファイルのページへのリンクを出します（出典とライセンスはそこにある）。
  """

  use GenServer

  import Ecto.Query

  alias Chidori.Chiezo
  alias Chidori.Relations.Face
  alias Chidori.Repo

  require Logger

  # 縮小版の横幅（Commons が受け付ける幅の一覧から。`Chidori.Artwork.thumb/2`）
  @width 120
  # 1 枚取るごとに空ける間（ミリ秒）
  @interval_ms 1_500
  # 1 枚の上限（縮小版はふつう 10KB 前後。大きすぎるものは写真ではない）
  @max_bytes 200_000

  def start_link(options),
    do: GenServer.start_link(__MODULE__, :ok, name: options[:name] || __MODULE__)

  @impl true
  def init(:ok), do: {:ok, %{queue: :queue.new(), queued: MapSet.new(), busy?: false}}

  @doc """
  写真の URL の並びのうち、**写しがあるもの**を `%{URL => 配る道}` で返し、
  まだ取りに行っていないものを取りに行く列に並べます。
  """
  def faces(urls) do
    urls = urls |> Enum.filter(&commons?/1) |> Enum.uniq()

    known =
      if urls == [],
        do: [],
        else:
          Repo.all(
            from(f in Face, where: f.source_url in ^urls, select: {f.source_url, f.id, f.status})
          )

    seen = MapSet.new(known, &elem(&1, 0))
    fetch(Enum.reject(urls, &MapSet.member?(seen, &1)))

    for {url, id, "ok"} <- known, into: %{}, do: {url, path(id)}
  rescue
    # 表がまだ無い（マイグレーションの前）ときも図は出す
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("顔写真の写しを読めませんでした: #{Exception.message(error)}")
      %{}
  end

  @doc "写しを配る道。"
  def path(id), do: "/faces/#{id}"

  @doc "Commons のファイルのページ（出典とライセンスはそこにある）。"
  def file_page(url) when is_binary(url) do
    if commons?(url),
      do: "https://commons.wikimedia.org/wiki/File:" <> Path.basename(url),
      else: nil
  end

  def file_page(_url), do: nil

  @doc "Commons の写真か（日本語版にだけある画像は取らない）。"
  def commons?(url) when is_binary(url),
    do: String.starts_with?(url, "https://upload.wikimedia.org/wikipedia/commons/")

  def commons?(_url), do: false

  @doc "写しを 1 枚読みます。"
  def get(id) do
    case Repo.get(Face, id) do
      %Face{status: "ok", image: image, content_type: type} when is_binary(image) ->
        {:ok, image, type}

      _other ->
        :error
    end
  end

  @doc false
  def fetch([]), do: :ok

  def fetch(urls) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:fetch, urls}), else: :ok
  end

  @impl true
  def handle_cast({:fetch, urls}, state) do
    fresh = Enum.reject(urls, &MapSet.member?(state.queued, &1))

    state = %{
      state
      | queue: Enum.reduce(fresh, state.queue, &:queue.in/2),
        queued: Enum.reduce(fresh, state.queued, &MapSet.put(&2, &1))
    }

    {:noreply, next(state)}
  end

  @impl true
  def handle_info(:next, state), do: {:noreply, next(%{state | busy?: false})}

  defp next(%{busy?: true} = state), do: state

  defp next(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, url}, rest} ->
        store(url, download(url))
        Process.send_after(self(), :next, @interval_ms)
        %{state | queue: rest, queued: MapSet.delete(state.queued, url), busy?: true}
    end
  end

  # **Wikimedia へは Chidori から出ない**。Chiezo に縮小版を作らせ（`POST /v1/thumbs`）、
  # その写しを Chiezo から受け取る（外への通信先を Chiezo だけにするため）
  defp download(url) do
    thumb = Chidori.Artwork.thumb(url, @width)

    with base when is_binary(base) <- Chiezo.base_url(),
         {:ok, path} <- Chiezo.thumb_of(base, thumb),
         {:ok, %{status: 200, body: body}} when byte_size(body) in 1..@max_bytes <-
           Chiezo.get(base <> path) do
      {:ok, body, "image/webp"}
    else
      # 取れない写真（無い・絵でない）は、取れなかったとして残す（取りに行き続けない）
      {:error, :no_image} ->
        Logger.info("顔写真を取れませんでした: #{thumb}")
        :missing

      {:ok, %{status: status}} ->
        Logger.info("顔写真を Chiezo から受け取れませんでした（#{status}）: #{thumb}")
        :retry

      # Chiezo につながらない・置いていない：残さない（次に図を開いたときに取り直す）
      other ->
        Logger.info("顔写真を取りに行けませんでした: #{inspect(other)}")
        :retry
    end
  end

  defp store(_url, :retry), do: :ok

  defp store(url, result) do
    attrs =
      case result do
        {:ok, body, type} -> %{source_url: url, image: body, content_type: type, status: "ok"}
        :missing -> %{source_url: url, image: nil, content_type: "", status: "missing"}
      end

    %Face{}
    |> Face.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :source_url)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("顔写真の写しを残せませんでした: #{Exception.message(error)}")
  end
end
