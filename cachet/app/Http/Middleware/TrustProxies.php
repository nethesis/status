<?php

/*
 * This file is part of Cachet.
 *
 * (c) Alt Three Services Limited
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Middleware\TrustProxies as LaravelTrustProxies;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response;

class TrustProxies extends LaravelTrustProxies
{
    /**
     * The headers that should be used to detect proxies.
     *
     * This property was missing in the original Cachet implementation,
     * causing Laravel to not detect HTTPS correctly when behind a reverse proxy.
     * See: https://laravel.com/docs/11.x/requests#configuring-trusted-proxies
     *
     * @var int
     */
    protected $headers =
        Request::HEADER_X_FORWARDED_FOR |
        Request::HEADER_X_FORWARDED_HOST |
        Request::HEADER_X_FORWARDED_PORT |
        Request::HEADER_X_FORWARDED_PROTO;

    /**
     * Handle an incoming request.
     *
     * @param \Closure(\Illuminate\Http\Request): (\Symfony\Component\HttpFoundation\Response) $next
     */
    public function handle(Request $request, Closure $next): Response
    {
        // Set proxies from configuration before handling the request
        $trustedProxies = config('cachet.trusted_proxies');
        if ($trustedProxies) {
            // If it's '*', trust all proxies, otherwise split by comma
            $this->proxies = ($trustedProxies === '*') ? '*' : explode(',', $trustedProxies);
        }

        return parent::handle($request, $next);
    }
}
