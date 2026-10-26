# builder と実行段は同じ Debian の版(いまは trixie)に揃える。リリースは builder の
# OpenSSL などに結び付いて焼かれるので、版が違うと実行段で起動できない
FROM hexpm/elixir:1.20.4-erlang-29.1.1-debian-trixie-20261005-slim AS builder

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV

COPY config config
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

# 資産はイメージの中で作る。手元にだけあるものを配ると、
# クリーンなチェックアウトから作ったイメージが無装飾になる
RUN mix compile \
  && mix assets.setup \
  && mix assets.deploy \
  && mix release

FROM debian:trixie-20261020-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad AS app

# libsctp1 は使わないが、無いと OTP 29 の VM が起動のたびに読み込み失敗の警告を出す
RUN apt-get update \
  && apt-get install --yes --no-install-recommends ca-certificates libstdc++6 libncurses6 openssl libsctp1 \
  && rm -rf /var/lib/apt/lists/* \
  && groupadd --system --gid 10001 chidori \
  && useradd --system --uid 10001 --gid chidori --create-home chidori

WORKDIR /app
COPY --from=builder --chown=chidori:chidori /app/_build/prod/rel/chidori ./

# 日本語を扱うので UTF-8 を明示する。空のままだと VM が latin1 で動き、
# Elixir が文字の扱いで警告を出す
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/app \
    PHX_SERVER=true \
    PORT=7000

USER chidori
EXPOSE 7000

# 起動のたびに移行を当ててから立てる。**リリースに Mix は入らない**ので
# `Chidori.Release.migrate/0` を呼ぶ。当て終わっている移行は飛ばされるだけなので、
# 何度起動しても同じ結果になる
CMD ["sh", "-c", "bin/chidori eval 'Chidori.Release.migrate()' && exec bin/chidori start"]
