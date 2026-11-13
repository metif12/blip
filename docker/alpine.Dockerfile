# syntax=docker/dockerfile:1

# blip on Alpine.
#
# Three images, one for each toolchain the project is willing to stand behind,
# and they are meant to be the same. What that means concretely: the V compiler
# is stock 0.5.2 in all three, because a project that builds on one V and
# ships another cannot claim to be the same language. `-cc gcc` everywhere,
# matching the README.
#
# The compiler comes from the official release archive, not a source build:
# building V means bootstrapping it, and the bootstrap needs its own C
# toolchain plus a contemporary vc snapshot -- a second pin hiding inside the
# first. The archive is the release the V team published, byte for byte.
# (Alpine is musl while the archive targets glibc, so gcompat is installed
# for the loader shims. If a future V stops running under it, the fallback
# is building the 0.5.2 tag from source on this image.)

FROM alpine:3.21

# build-base is gcc, make and the rest of the C toolchain. curl and unzip are
# what fetching the stock compiler needs; gcompat shims the glibc loader.
RUN apk add --no-cache build-base curl unzip gc-dev gcompat

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
