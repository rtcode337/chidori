defmodule TazunaWeb.FullscreenButton do
  @moduledoc """
  図の「全画面」のボタン。**字ではなくアイコンにする** —— スマホでは図の上の道具
  （検索欄・拡大・縮小・全体）と横に並びきらず、「全画面」の字のぶんで重なっていた。
  関連図・トピックの網・区画の地図の 3 か所で同じもの（押したときの動きは
  `data-zoom="full"` を受ける図の側が持つ）。
  """

  use Phoenix.Component

  def fullscreen_button(assigns) do
    ~H"""
    <button
      type="button"
      class="icon-button"
      data-zoom="full"
      aria-label="全画面で見る"
      title="全画面で見る"
    >
      <svg viewBox="0 0 24 24" width="18" height="18" aria-hidden="true" focusable="false">
        <path
          d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"
          fill="none"
          stroke="currentColor"
          stroke-width="2.2"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
    </button>
    """
  end
end
