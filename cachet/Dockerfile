# Multi-stage build for production Cachet deployment
ARG PHP_VERSION=8.3

# ============================================
# Stage 1: Composer dependencies
# ============================================
FROM docker.io/library/php:${PHP_VERSION}-cli-alpine AS composer

# Install composer and required extensions
RUN apk add --no-cache \
    composer \
    icu-dev \
    libxml2-dev \
    && docker-php-ext-install \
        intl \
        dom \
        xml \
    && php -m | grep -i intl \
    && php -m | grep -i dom

WORKDIR /app

# Copy composer files and core directory
# Build context is podman-setup directory, so:
# - ./core is podman-setup/core
# - ./cachet is podman-setup/cachet
# Core must be at ../core relative to /app for composer path repository to work
COPY ./core /core
COPY ./cachet/composer.json ./cachet/composer.lock ./

# Install dependencies (including dev for now - Pail is required by config/app.php)
# Note: We ignore platform requirements for extensions that are:
# - Bundled in PHP 8.3 (fileinfo, session, tokenizer, simplexml, xmlreader, xmlwriter)
# - Installed but not detected correctly by composer (intl, dom, xml)
RUN composer install \
    --no-interaction \
    --no-progress \
    --no-scripts \
    --prefer-dist \
    --optimize-autoloader \
    --ignore-platform-req=php+ \
    --ignore-platform-req=ext-simplexml \
    --ignore-platform-req=ext-fileinfo \
    --ignore-platform-req=ext-session \
    --ignore-platform-req=ext-tokenizer \
    --ignore-platform-req=ext-xmlreader \
    --ignore-platform-req=ext-xmlwriter \
    --ignore-platform-req=ext-intl \
    --ignore-platform-req=ext-dom \
    --ignore-platform-req=ext-xml

# PRODUCTION FIX: Replace symlink with actual core files
# This ensures core is properly available regardless of symlink issues
RUN rm -rf /app/vendor/cachethq/core \
    && cp -r /core /app/vendor/cachethq/core

# ============================================
# Stage 2: Node.js dependencies and build
# ============================================
FROM docker.io/library/node:20-alpine AS node

# Build context is podman-setup, so core is at ./core
WORKDIR /build-core

# Copy core's package files
COPY ./core/package.json ./core/package-lock.json ./
COPY ./core/vite.config.js ./core/jsconfig.json ./

# Install node dependencies (including dev dependencies for vite build)
RUN npm ci

# Copy vendor from composer stage (needed for filament CSS imports)
COPY --from=composer /app/vendor ./vendor

# Copy core's source files for building
COPY ./core/resources ./resources
COPY ./core/public ./public

# Build core assets
RUN npm run build

# ============================================
# Stage 3: Production PHP runtime
# ============================================
FROM docker.io/library/php:${PHP_VERSION}-fpm-alpine

# Install system dependencies
RUN apk add --no-cache \
    nginx \
    supervisor \
    postgresql-dev \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    oniguruma-dev \
    icu-dev \
    libxml2-dev \
    curl \
    bash \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo_pgsql \
        pgsql \
        zip \
        gd \
        mbstring \
        intl \
        dom \
        xml \
    && rm -rf /var/cache/apk/*

# Install PHP extensions for production
RUN docker-php-ext-enable opcache

# Configure PHP for production (relative to podman-setup)
COPY ./cachet/docker/php/php.ini /usr/local/etc/php/conf.d/cachet.ini
COPY ./cachet/docker/php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini

# Configure Nginx
COPY ./cachet/docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./cachet/docker/nginx/default.conf /etc/nginx/http.d/default.conf

# Configure Supervisor
COPY ./cachet/docker/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Create application user
RUN addgroup -g 1000 -S cachet && \
    adduser -u 1000 -S cachet -G cachet

# Set working directory
WORKDIR /var/www/html

# Copy application files (relative to podman-setup)
COPY --chown=cachet:cachet ./cachet/. .

# Copy composer dependencies from builder
# Note: With symlink=false in composer.json, core is copied into vendor/cachethq/core
COPY --from=composer --chown=cachet:cachet /app/vendor ./vendor

# Copy built assets from node builder (in /build-core/public/build)
COPY --from=node --chown=cachet:cachet /build-core/public/build ./public/build

# Publish Cachet assets (config, views, and public assets)
RUN php artisan vendor:publish --tag=cachet --force

# Publish Livewire config and views
RUN php artisan livewire:publish

# Publish Filament assets (required for dashboard login to work)
RUN php artisan filament:assets

# Create storage symlink for public uploads (banner, ecc.)
RUN php artisan storage:link

# Fix permissions AFTER artisan commands - PHP-FPM runs as www-data
# Important: artisan commands may create files as cachet user, so we fix ownership
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 775 /var/www/html/storage \
    && chmod -R 775 /var/www/html/bootstrap/cache

# Create necessary directories
RUN mkdir -p /var/www/html/storage/framework/{sessions,views,cache} \
    && mkdir -p /var/www/html/storage/logs \
    && mkdir -p /var/log/supervisor \
    && mkdir -p /var/run/supervisor \
    && chown -R www-data:www-data /var/www/html/storage \
    && chown -R www-data:www-data /var/www/html/bootstrap/cache

# Expose port 80 for Nginx
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD php artisan cachet:health || exit 1

# Start supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
