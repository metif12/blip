# syntax=docker/dockerfile:1

# blip on Debian.
#
# The same stock V 0.5.2 compiler as docker/alpine.Dockerfile, fetched the
# same way. The two images differ only in the C toolchain, which is the entire
# point of there being two: a language that only builds on one libc is a
# language with a portability bug nobody has found yet.
#
# trixie-slim rather than debian:stable, because "stable" is a moving pointer
# and a build that worked on Tuesday should work on Friday.

FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential curl ca-certificates unzip libgc-dev \
    && rm -rf /var/lib/apt/lists/*

# The compiler this project targets: the official 0.5.2 release.
ARG V_VERSION=0.5.2

WORKDIR /opt
RUN curl -sSL -o v.zip "https://github.com/vlang/v/releases/download/${V_VERSION}/v_linux.zip" \
    && unzip -q v.zip \
    && rm v.zip \
    && ./v/v -version

ENV PATH=/opt/v:$PATH

# The prelude lives beside the binary. std_path() looks for lib/std.lip two
# levels up from the executable, so a binary in /usr/local/bin needs it in
# /usr/local/lib. Without it the image builds and then every program fails to
# load the standard library, which is the sort of thing that only shows up on
# someone else's machine.
COPY lib/std.lip /usr/local/lib/std.lip

COPY . /src
WORKDIR /src

RUN v -cc gcc -path 'vlib|@vlib' -o /usr/local/bin/blip main.v \
    && blip version

# /w is where a program gets mounted, so the image is runnable rather than
# something you have to enter to use.
WORKDIR /w

ENTRYPOINT ["blip"]
CMD ["--help"]
