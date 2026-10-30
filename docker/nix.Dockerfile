# syntax=docker/dockerfile:1

# blip on Nix.
#
# The toolchain comes from nixpkgs rather than a distro package manager, and
# the pinned V compiler is still built from the same commit as the Alpine and
# Debian images. Nix is the third image because it is the third way people get
# a C toolchain, not because the build is different.
#
# What Nix buys is exactness: gcc and its headers are the same on every run, so
# a failure here cannot be "an old Debian had a different glibc".
#
# The base is `nixos/nix:latest` rather than a version tag, because the tag the
# image was first written against (`nixos/nix:2.25`) does not exist upstream --
# the build failed on `load metadata` before reaching a single instruction, and
# a tag that predicts a future Nix is worse than `latest` that holds what is
# published now.

FROM nixos/nix:latest

# One `nix-env -iA` per package, in a shell loop.
#
# `nix-env -iA nixpkgs.gcc nixpkgs.gnumake` in one call installs some of them
# and silently skips the rest -- `make` was missing from the default profile
# afterwards while `git` and `curl` were there, which is the failure this loop
# is written to avoid.
RUN nix-channel --update \
    && nix-env -iA \
        nixpkgs.gnumake \
        nixpkgs.gcc \
        nixpkgs.git \
        nixpkgs.curl \
        nixpkgs.boehmgc

# The nix profile directories are not on PATH for a fresh shell the way /usr/bin
# is. Without this `make` is not found on the very first build command.
ENV PATH=/nix/var/nix/profiles/default/bin:/root/.nix-profile/bin:$PATH

# The commit this project targets. Not the 0.5.2 release: vlang/v master at
# this commit also reports itself as "V 0.5.2" and resolves modules
# differently, which is the difference the project was bitten by.
ARG V_COMMIT=74be97a2d7bd1fce4150abc749a2e64b21d9d082

# vc is a SEPARATE repository from V and the Makefile clones it at HEAD,
# unpinned. That is what broke this: a vc snapshot generated from a newer V
# carries a parser that rejects the pinned V's own vlib -- vc HEAD gained
# "reject `if` conditions that start with a parenthesized if expression" on
# 2026-10-05, and vlib/math/bits/bits.v at this V_COMMIT uses that shape at
# line 621. This is the vc snapshot taken just after V_COMMIT.
ARG VC_COMMIT=0027130e9850c9946fa2c21e9004f13d8e593595

WORKDIR /opt
# V's own build runs git to stamp the version, and a container's repository has
# no configured owner, so the directory is marked safe up front.
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
    && (cp $(find /nix/store -name 'libgc.so' -o -name 'libgc.a' 2>/dev/null | head -1 | xargs dirname 2>/dev/null)/libgc.a thirdparty/tcc/lib/libgc.a 2>/dev/null || true) \
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
