# syntax=docker/dockerfile:1

# blip on Nix.
#
# The toolchain comes from nixpkgs rather than a distro package manager, and
# the V compiler is the same stock 0.5.2 release as the Alpine and Debian
# images. Nix is the third image because it is the third way people get
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
        nixpkgs.gcc \
        nixpkgs.curl \
        nixpkgs.unzip \
        nixpkgs.boehmgc

# The nix profile directories are not on PATH for a fresh shell the way /usr/bin
# is. Without this `curl` is not found on the very first build command.
ENV PATH=/nix/var/nix/profiles/default/bin:/root/.nix-profile/bin:$PATH

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
