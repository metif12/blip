# syntax=docker/dockerfile:1

# blip on Debian.
#
# The same pinned V compiler as docker/alpine.Dockerfile, built the same way.
# The two images differ only in the C toolchain, which is the entire point of
# there being two: a language that only builds on one libc is a language with a
# portability bug nobody has found yet.
#
# trixie-slim rather than debian:stable, because "stable" is a moving pointer
# and a build that worked on Tuesday should work on Friday.

FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ca-certificates libgc-dev \
    && rm -rf /var/lib/apt/lists/*

# The commit this project targets. Not the 0.5.2 release: vlang/v master at
# this commit also reports itself as "V 0.5.2" and resolves modules
# differently, which is the difference the project was bitten by.
# vc is a SEPARATE repository from V and the Makefile clones it at HEAD,
# unpinned. That is what broke this: a vc snapshot generated from a newer V
# carries a parser that rejects the pinned V's own vlib -- vc HEAD gained
# "reject `if` conditions that start with a parenthesized if expression" on
# 2026-10-05, and vlib/math/bits/bits.v at this V_COMMIT uses that shape at
# line 621. This is the vc snapshot taken just after V_COMMIT.
ARG V_COMMIT=74be97a2d7bd1fce4150abc749a2e64b21d9d082

# Building the `v` target directly rather than `all`, because `all` depends on
# download_vc, which clones vc at HEAD and undoes the pin.
ARG VC_COMMIT=0027130e9850c9946fa2c21e9004f13d8e593595

WORKDIR /opt
RUN git init -q v \
    && cd v \
    && git remote add origin https://github.com/vlang/v.git \
    && git fetch -q --depth 1 origin "$V_COMMIT" \
    && git checkout -q FETCH_HEAD \
    && git clone -q https://github.com/vlang/vc vc \
    && git -C vc fetch -q --depth 1 origin "$VC_COMMIT" \
    && git -C vc checkout -q FETCH_HEAD \
    && mkdir -p thirdparty/tcc/lib \
    && cp /usr/lib/x86_64-linux-gnu/libgc.a thirdparty/tcc/lib/libgc.a 2>/dev/null || cp /usr/lib/libgc.a thirdparty/tcc/lib/libgc.a 2>/dev/null || true \
    && make -f Makefile v VFLAGS="-d use_bundled_libgc" \
    && ./v -version

ENV PATH=/opt/v:$PATH

# The prelude lives beside the binary. std_path() looks for lib/std.lip two
# levels up from the executable, so a binary in /usr/local/bin needs it in
# /usr/local/lib. Without it the image builds and then every program fails to
# load the standard library, which is the sort of thing that only shows up on
# someone else's machine.
COPY lib/std.lip /usr/local/lib/std.lip

COPY . /src
WORKDIR /src

RUN v -cc gcc -o /usr/local/bin/blip blip.v \
    && blip version

# /w is where a program gets mounted, so the image is runnable rather than
# something you have to enter to use.
WORKDIR /w

ENTRYPOINT ["blip"]
CMD ["--help"]
