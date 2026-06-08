# glibc-2.34 build environment (Ubuntu 22.04) so the binary runs on any x86_64
# distro with glibc >= 2.34, matching slsteam-moon's portable build.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates pkg-config \
    liblua5.4-dev lua5.4 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
