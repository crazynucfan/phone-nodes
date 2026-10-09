# syntax=docker/dockerfile:1
# Cross-compiles a phone's kernel from its patch series. Everything runs on the
# build platform (the amd64 BuildKit daemon in CI); only the `artifacts` stage
# leaves the builder: Image.gz, the DTB, stripped modules, the Debian packages
# (debs/) and build metadata.
#
#   docker buildx build --target artifacts --build-arg DEVICE=negroni \
#       --build-arg BUILD_ID=local --output type=local,dest=out/negroni .
#
# The `distccd` target is the compile server CI spreads the compiling over
# (DISTCC_POOL below).

ARG DEBIAN=docker.io/library/debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

FROM --platform=$BUILDPLATFORM ${DEBIAN} AS toolchain
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        bc bison build-essential ca-certificates ccache cpio debhelper distcc \
        dpkg-dev dwarves flex gcc-aarch64-linux-gnu git kmod libdw-dev \
        libelf-dev libssl-dev python3 rsync zstd \
 && rm -rf /var/lib/apt/lists/*

# A distcc server: this very toolchain, so it compiles with the same compiler
# as the build (build.sh checks that before using a server anyway). distccd
# only runs compilers linked from /usr/lib/distcc. Run it with
# --allow set to the network of the machines that build.
FROM toolchain AS distccd
RUN ln -sf ../../bin/distcc /usr/lib/distcc/aarch64-linux-gnu-gcc
USER 65534:65534
EXPOSE 3632
ENTRYPOINT ["distccd", "--daemon", "--no-detach", "--log-stderr", "--listen", "0.0.0.0"]

# The upstream source as its own layer. Its only inputs are the device's BASE
# and fetch.sh, so BuildKit reuses it from the layer cache until BASE changes:
# patch, config and script changes rebuild from here without touching
# kernel.org. About 1.5 GB (checkout plus a shallow .git).
FROM toolchain AS source
ARG DEVICE=negroni
COPY ${DEVICE}/BASE /phone-kernel/${DEVICE}/BASE
COPY scripts/fetch.sh /phone-kernel/scripts/fetch.sh
RUN bash /phone-kernel/scripts/fetch.sh "${DEVICE}" /src

FROM source AS build
ARG DEVICE=negroni
ARG BUILD_ID=local
ARG INPUT_KEY=local
# DISTCC_POOL=<dns name>[,<dns name>...][/<jobs per server>] spreads the
# compiling over the distcc servers the first name with a usable server
# resolves to (see build.sh). Unset, or when none answers with the same
# compiler, everything compiles here.
ARG DISTCC_POOL=
# The ccache lives in a BuildKit cache mount, so it survives between builds on
# the same daemon without ever landing in a layer. build.sh applies the series
# on top of /src and deletes its build tree before the layer is committed, so
# this layer holds the patched files and /out only.
# Shared by every device; apollo's objects carry full DWARF (for BTF).
ENV CCACHE_DIR=/ccache CCACHE_MAXSIZE=8G CCACHE_COMPRESS=1
COPY scripts/ /phone-kernel/scripts/
COPY ${DEVICE}/ /phone-kernel/${DEVICE}/
RUN --mount=type=cache,target=/ccache,id=phone-kernel-ccache \
    SRC=/src bash /phone-kernel/scripts/build.sh "${DEVICE}" "${BUILD_ID}" /out \
 && bash /phone-kernel/scripts/check-artifacts.sh "${DEVICE}" /out \
 && printf '%s\n' "${INPUT_KEY}" > /out/input-key \
 && { ccache --show-stats | sed -n '1,12p' || true; }

FROM scratch AS artifacts
ARG DEVICE=negroni
ARG VERSION=dev
ARG COMMIT_SHA=unknown
LABEL org.opencontainers.image.title="phone-kernel-${DEVICE}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${COMMIT_SHA}"
COPY --from=build /out/ /
