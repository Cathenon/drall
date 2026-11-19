
#!/bin/sh
set -eu

echo "=== Drall startup ==="

# Required environment variables
: "${APP_KEY:?APP_KEY must be configured in Railway}"
: "${DB_HOST:?DB_HOST must be configured in Railway}"
: "${DB_DATABASE:?DB_DATABASE must be configured in Railway}"
: "${DB_USERNAME:?DB_USERNAME must be configured in Railway}"
: "${DB_PASSWORD:?DB_PASSWORD must be configured in Railway}"

DB_PORT="${DB_PORT:-3306}"
PORT="${PORT:-8080}"

# Wait for MySQL
echo "Waiting for MySQL..."

attempt=0
until php -r '
$host = getenv("DB_HOST");
$port = (int) (getenv("DB_PORT") ?: 3306);
$s = @fsockopen($host, $port, $errno, $errstr, 3);
if ($s) {
    fclose($s);
    exit(0);
}
exit(1);
'; do
    attempt=$((attempt + 1))

    if [ "$attempt" -ge 30 ]; then
        echo "ERROR: MySQL unavailable after 30 attempts."
        exit 1
    fi

    sleep 2
done

echo "MySQL is reachable."

# Create Laravel directories
mkdir -p storage/framework/views \
         storage/framework/cache \
         storage/framework/sessions \
         storage/logs \
         bootstrap/cache

# Permissions
chmod -R 775 storage bootstrap/cache

# Check storage link without deleting existing files
if [ ! -L public/storage ] && [ ! -e public/storage ]; then
    php artisan storage:link
elif [ -L public/storage ] && [ -e public/storage ]; then
    echo "Storage symlink already exists."
else
    echo "ERROR: public/storage exists but is not a valid symlink."
    echo "Inspect it manually before proceeding."
    exit 1
fi

# Apply pending migrations
php artisan migrate --force --no-interaction

# First boot: install without the web installer
HAS_ADMIN="$(php artisan tinker --execute='echo (Schema::hasTable("admins") && DB::table("admins")->count() > 0) ? "yes" : "no";' 2>/dev/null | tail -n 1 | tr -d '[:space:]')"

if [ "$HAS_ADMIN" != "yes" ]; then
    [ -f .env ] || cp .env.example .env
    for key in APP_URL DB_CONNECTION DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD; do
        value="$(printenv "$key" || true)"
        if [ -n "$value" ]; then
            if grep -q "^${key}=" .env; then sed -i "s|^${key}=.*|${key}=${value}|" .env
            else echo "${key}=${value}" >> .env; fi
        fi
    done
    php artisan bagisto:install --no-interaction --force
    ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}" ADMIN_PASSWORD="${ADMIN_PASSWORD:-}" \
    php artisan tinker --execute='if (getenv("ADMIN_PASSWORD")) { DB::table("admins")->update(["email" => getenv("ADMIN_EMAIL"), "password" => bcrypt(getenv("ADMIN_PASSWORD"))]); }'
fi
touch storage/installed

# Start Laravel
echo "Starting Drall on port $PORT"

exec php artisan serve --host=0.0.0.0 --port="$PORT"
