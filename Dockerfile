# glibc-2.34 build environment (Ubuntu 22.04) so the binary runs on any x86_64
# distro with glibc >= 2.34, matching slsteam-moon's portable build.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates pkg-config curl perl \
    liblua5.4-dev lua5.4 \
    && rm -rf /var/lib/apt/lists/*

# Static OpenSSL + libcurl built from pinned source into /opt/static, so the
# lumen binary has NO TLS/curl runtime dependency (Ubuntu's libcurl.a pulls
# dynamic libssl.so + gssapi/ldap; building our own avoids all of it).
ARG OPENSSL_VER=3.0.13
RUN curl -sL https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz | tar xz && \
    cd openssl-${OPENSSL_VER} && \
    ./Configure no-shared no-tests linux-x86_64 --prefix=/opt/static && \
    make -j"$(nproc)" && make install_sw && \
    cd .. && rm -rf openssl-${OPENSSL_VER}

ARG CURL_VER=8.7.1
RUN curl -sL https://curl.se/download/curl-${CURL_VER}.tar.gz | tar xz && \
    cd curl-${CURL_VER} && \
    PKG_CONFIG_PATH=/opt/static/lib64/pkgconfig:/opt/static/lib/pkgconfig \
    ./configure --disable-shared --enable-static \
        --with-openssl=/opt/static --prefix=/opt/static \
        --disable-ldap --disable-ldaps --disable-manual --disable-libcurl-option \
        --without-libpsl --without-librtmp --without-brotli --without-zstd \
        --without-nghttp2 --without-libidn2 && \
    make -j"$(nproc)" && make install && \
    cd .. && rm -rf curl-${CURL_VER}

WORKDIR /build
