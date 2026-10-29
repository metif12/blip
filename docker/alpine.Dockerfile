# syntax=docker/dockerfile:1

# blip on Alpine.
#
# Three images, one for each toolchain the project is willing to stand behind,
# and they are meant to be the same. What that means concretely: the V compiler
# is built from the same pinned commit in all three, because a project pinned to
# a specific compiler cannot ship an image built by a different one and claim to
# be the same language. `-cc gcc` everywhere, matching the README.
#
# multi-stage would break that. A multi-stage build that copies a prebuilt
# compiler in from a builder stage is fine; one that downloads a binary can only
# produce a V that cannot find its vlib beside it, which the repo's own notes
# on the 0.5.2 release archive already say.

FROM alpine:3.21

# build-base is gcc, make and the rest of the C toolchain. git and curl are
# what fetching the pinned compiler needs.
RUN apk add --no-cache build-base git curl gc-dev

# The commit this project targets. Not the 0.5.2 release: vlang/v master at
# this commit also reports itself as "V 0.5.2" and resolves modules
# differently, which is the difference the project was bitten by.
ARG V_COMMIT=b9ebf8baff04133e1cb131c6d77dfb28008217b6

# vc is the C source V bootstraps itself from, and it lives in a SEPARATE
# repository from V. The Makefile clones it at HEAD -- unpinned -- which is what
# broke the build: a vc snapshot generated from a newer V carries a parser that
# rejects the pinned V's own vlib. vc HEAD gained "reject `if` conditions that
# start with a parenthesized if expression" on 2026-10-05, and
# vlib/math/bits/bits.v at this V_COMMIT uses exactly that shape at line 621, so
# `make` died compiling a file the pinned commit itself ships.
#
# This is the vc snapshot taken just after V_COMMIT and before that change. The
# `v` target is built directly rather than through `all`, because `all` depends
# on download_vc, which clones vc at HEAD and undoes the pin.
ARG VC_COMMIT=8fb9f78d04e564a4e556d9a4eaea63067d341030

WORKDIR /opt
RUN git config --global --add safe.directory /opt/v \
    && git config --global --add safe.directory /opt/v/vc \
    && git init -q v \
    && cd v \
    && git remote add origin https://github.com/vlang/v.git \
    && git fetch -q --depth 1 origin "$V_COMMIT" \
    && git checkout -q FETCH_HEAD \
    && git clone -q https://github.com/vlang/vc vc \
    && git -C vc fetch -q --depth 1 origin "$VC_COMMIT" \
    && git -C vc checkout -q FETCH_HEAD \
    && mkdir -p thirdparty/tcc/lib \
    && cp /usr/lib/libgc.a thirdparty/tcc/lib/libgc.a 2>/dev/null || cp /lib/libgc.a thirdparty/tcc/lib/libgc.a 2>/dev/null || true \
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
