<?php

namespace Database\Seeders;

use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;
use App\Models\User;
use Laravel\Sanctum\PersonalAccessToken;

class AdminSeeder extends Seeder
{
    public function run()
    {
        $adminEmail = env('CACHET_ADMIN_USERNAME');
        $adminName = env('CACHET_ADMIN_NAME');
        $adminPassword = env('CACHET_ADMIN_PASSWORD');

        // Step 1: Check if admin user exists
        $adminUser = User::where('email', $adminEmail)->first();

        if (!$adminUser) {
            // Step 2: Create admin user if not exists
            $adminUser = User::create([
                'name' => $adminName,
                'email' => $adminEmail,
                'password' => Hash::make($adminPassword),
                'is_admin' => true,
            ]);
            $this->command->info("Admin user created: {$adminEmail}");
        } else {
            $this->command->info("Admin user already exists: {$adminEmail}");
        }

        // Step 3: Check for existing valid token
        $existingToken = PersonalAccessToken::where('tokenable_id', $adminUser->id)
            ->where('tokenable_type', User::class)
            ->where(function ($query) {
                $query->whereNull('expires_at')
                      ->orWhere('expires_at', '>', now());
            })
            ->first();

        if ($existingToken) {
            $this->command->info("Valid token already exists for admin user.");
            $token = $existingToken->token;
        } else {
            // Step 4: Generate new token if none exists or if expired
            $token = $adminUser->createToken('Middleware API Token', ['*'])->plainTextToken;
            $this->command->info("New token generated for admin user.");
        }

        $this->command->info("Generated Token: {$token}");
    }
}