# Multi-stage build for production Cachet deployment
ARG PHP_VERSION

# ============================================
# Stage 1: Composer dependencies
# ============================================
FROM docker.io/library/php:${PHP_VERSION}-cli-alpine AS composer

# Allow use of all user's SSH keys/config for private repository authentication
# Temporarily copy the entire .ssh directory
COPY --chown=root:root .ssh /root/.ssh
RUN chmod 700 /root/.ssh && chmod 600 /root/.ssh/*

ENV GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=yes"

# Install composer and required extensions
RUN apk add --no-cache \
    composer \
    icu-dev \
    libxml2-dev \
    && docker-php-ext-install \
        intl \
        dom \
        xml \
        simplexml \
        session \
    && php -m | grep -i intl \
    && php -m | grep -i dom \
    && php -m | grep -i simplexml \
    && php -m | grep -i tokenizer \
    && php -m | grep -i session

WORKDIR /app

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

# Update cachethq/core dependency
RUN composer update cachethq/core --no-interaction --no-dev --prefer-dist

# Remove SSH keys after use for security
RUN rm -rf /root/.ssh

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
        simplexml \
        session \
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

# Publish Cachet assets (config, views, and public assets)
RUN php artisan vendor:publish --tag=cachet --force

# Copy custom images (from build context) into the published vendor folder (overwrite default images)
COPY ./cachet-configuration-files/images/ /var/www/html/public/vendor/cachethq/cachet/

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
