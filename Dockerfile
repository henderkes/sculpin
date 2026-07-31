FROM alpine:3.21

RUN apk update && \
    apk upgrade -a && \
    apk add --no-cache \
        autoconf \
        automake \
        gettext \
        bash \
        binutils \
        bison \
        build-base \
        cmake \
        curl \
        file \
        flex \
        g++ \
        gcc \
        git \
        jq \
        libgcc \
        libtool \
        libstdc++ \
        linux-headers \
        m4 \
        make \
        pkgconfig \
        re2c \
        wget \
        xz \
        gettext-dev \
        binutils-gold

WORKDIR /app

RUN curl -#fSL https://getcomposer.org/download/latest-stable/composer.phar -o /usr/local/bin/composer && \
    chmod +x /usr/local/bin/composer && \
    curl -#fSL https://github.com/box-project/box/releases/download/4.7.0/box.phar -o /usr/local/bin/box && \
    chmod +x /usr/local/bin/box

# Every arch builds natively with gcc, so each image runs on its own platform (arm under
# emulation) and no prebuilt spc applies - static-php.dev only publishes x86_64/aarch64, and
# spc's own arch2gnu() refuses arm32 outright, with the armv7 mapping commented out upstream.
# Run spc.phar's sources on Alpine's php instead, with that mapping enabled.
RUN apk add --no-cache php84 php84-ctype php84-curl php84-dom php84-fileinfo php84-iconv \
        php84-mbstring php84-openssl php84-pcntl php84-phar php84-posix php84-session \
        php84-simplexml php84-tokenizer php84-xml php84-xmlwriter php84-zip && \
    ln -sf /usr/bin/php84 /usr/local/bin/php && \
    curl -#fSL https://dl.static-php.dev/v3/spc-bin/nightly/spc.phar -o /tmp/spc.phar && \
    php -r '(new Phar("/tmp/spc.phar"))->extractTo("/opt/spc");' && rm /tmp/spc.phar && \
    sed -i "s/'arm64', 'aarch64' => 'aarch64',/'arm64', 'aarch64' => 'aarch64', 'armv7l', 'armv7' => 'arm',/" /opt/spc/src/globals/functions.php && \
    grep -q "'armv7l'" /opt/spc/src/globals/functions.php && \
    printf '%s\n' '#!/bin/sh' 'exec php /opt/spc/bin/spc "$@"' > /usr/local/bin/spc && \
    chmod +x /usr/local/bin/spc

# spc's pkg-config artifact is a binary-only download with no arm build; Alpine's pkgconf does
# the same job, and pointing PKG_ROOT_PATH at it leaves the doctor nothing to fix.
RUN mkdir -p /opt/spc-pkgroot/bin && \
    ln -sf /usr/bin/pkg-config /opt/spc-pkgroot/bin/pkg-config

# The toolchain is chosen in spc's bootstrap, before craft.yml's extra-env is applied, and
# `spc doctor` never reads craft.yml at all - so these have to come from the environment.
# SPC_TARGET must be empty rather than unset: unset is what makes env.ini apply its zig default.
ENV SPC_TOOLCHAIN="StaticPHP\\Toolchain\\GccNativeToolchain" \
    SPC_TARGET="" \
    SPC_LIBC=musl \
    PKG_ROOT_PATH=/opt/spc-pkgroot

RUN spc doctor --auto-fix -vvv

ARG ARCH
# 32-bit only: php_micro_fileinfo.c omits `typedef Elf32_Shdr Elf_Shdr` in its non-LP64 branch
ARG PHP_CFLAGS_EXTRA=""

COPY ./composer.* /app/
COPY ./craft.yml.twig /app/craft.yml.twig
COPY ./box.json.dist /app/box.json
COPY ./bin /app/bin
COPY ./src /app/src

# The php running composer is the builder's, not the 8.5 micro the phar ends up on - Alpine's
# is 8.4, so the platform check has nothing to say here.
RUN --mount=type=cache,target=/app/downloads,sharing=locked \
    envsubst < craft.yml.twig > craft.yml && \
    composer install --no-dev --ignore-platform-req=php && \
    spc craft && box compile && spc micro:combine bin/sculpin.phar && \
    mv my-app sculpin-linux-${ARCH:-$(uname -m)}
