# Single-stage build for production Cachet deployment
ARG PHP_VERSION=8.3
ARG CACHET_COMMIT=207a6d5a7c309fcdc4656a074869f0afa06d142c

FROM docker.io/library/php:${PHP_VERSION}-fpm-alpine

# Install system dependencies and composer
RUN apk add --no-cache \
    composer \
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
    libpq \
    icu-libs \
    libjpeg-turbo \
    libpng \
    freetype \
    libzip \
    oniguruma \
    libxml2 \
    curl \
    bash \
    git \
    autoconf \
    g++ \
    make \
    ca-certificates \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j$(nproc) \
        pdo \
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
    && docker-php-ext-enable opcache pdo pdo_pgsql

# Configure PHP for production (relative to podman-setup)
COPY ./docker/php/php.ini /usr/local/etc/php/conf.d/cachet.ini
COPY ./docker/php/opcache.ini /usr/local/etc/php/conf.d/opcache.ini

# Configure Nginx
COPY ./docker/nginx/nginx.conf /etc/nginx/nginx.conf
COPY ./docker/nginx/default.conf /etc/nginx/http.d/default.conf

# Configure Supervisor
COPY ./docker/supervisor/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Set working directory
WORKDIR /var/www/html

# Clone Cachet repository
RUN git clone https://github.com/cachethq/cachet.git /var/www/html/ \
    && git --git-dir /var/www/html/.git checkout ${CACHET_COMMIT}

# Copy local configuration files into the cloned Cachet repository
COPY --chown=root:root ./proxy/TrustProxies.php /var/www/html/app/Http/Middleware/TrustProxies.php

# Copy AdminSeeder to enable admin user creation via environment variables
COPY ./token/AdminSeeder.php /var/www/html/database/seeders/AdminSeeder.php

# Install composer dependencies (no dev)
# Note: We ignore platform requirements for extensions that are:
# - Bundled in PHP 8.3 (fileinfo, session, tokenizer, simplexml, xmlreader, xmlwriter)
# - Installed but not detected correctly by composer (intl, dom, xml)
RUN cd /var/www/html && composer install --no-dev \
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

# Clear composer cache to save space
RUN composer clear-cache

# Remove .git folder to save space
RUN rm -rf .git

# Publish Cachet assets (config, views, and public assets)
RUN php artisan vendor:publish --tag=cachet --force

# Copy custom images (from build context) into the published vendor folder (overwrite default images)
# build context is cachet-configuration-files, so images are in ./images/
COPY ./images/ /var/www/html/public/vendor/cachethq/cachet/

# Publish Livewire config and views
RUN php artisan livewire:publish

# Publish Filament assets (required for dashboard login to work)
RUN php artisan filament:assets

# Create storage symlink for public uploads (banner, ecc.)
RUN php artisan storage:link

# Ensure migrations for database-backed drivers exist
RUN php artisan cache:table || true
RUN php artisan session:table || true
RUN php artisan queue:table || true

# Fix permissions AFTER artisan commands - PHP-FPM runs as www-data
RUN chmod -R 775 /var/www/html/storage \
    && chmod -R 775 /var/www/html/bootstrap/cache

# Create necessary directories
RUN mkdir -p /var/www/html/storage/framework/{sessions,views,cache} \
    && mkdir -p /var/www/html/storage/logs \
    && mkdir -p /var/log/supervisor \
    && mkdir -p /var/run/supervisor \
    && chown -R www-data:www-data /var/www/html

# Clean up build dependencies
RUN apk del -r --no-cache \
    postgresql-dev \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    freetype-dev \
    oniguruma-dev \
    icu-dev \
    libxml2-dev \
    autoconf \
    g++ \
    make \
    git \
    ca-certificates \
    && rm -rf /var/cache/apk/*
    
# Expose port 80 for Nginx
EXPOSE 80

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD php artisan cachet:health || exit 1

# Start supervisor
CMD ["sh", "-c", "until php artisan migrate --force; do echo 'Waiting for database...'; sleep 2; done && /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf"]
