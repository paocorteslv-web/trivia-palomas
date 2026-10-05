#!/usr/bin/env sh
# Genera config.js desde variables de entorno (para Netlify, Vercel, Cloudflare Pages, etc.):
#   SUPABASE_URL=https://xxx.supabase.co SUPABASE_ANON_KEY=eyJ... sh scripts/make-config.sh
set -eu
: "${SUPABASE_URL:?Falta SUPABASE_URL}"; : "${SUPABASE_ANON_KEY:?Falta SUPABASE_ANON_KEY}"
case "$SUPABASE_ANON_KEY" in sb_secret_*) echo "ERROR: esa es una clave secreta; usá la anon/publishable" >&2; exit 1;; esac
ROLE=$(printf '%s' "$SUPABASE_ANON_KEY" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | grep -o '"role":"[a-z_]*"' || true)
[ "$ROLE" = '"role":"service_role"' ] && { echo "ERROR: esa es la clave service_role; usá la anon" >&2; exit 1; }
printf 'window.CARRITO_CONFIG={url:%s,anonKey:%s};\n' "\"$SUPABASE_URL\"" "\"$SUPABASE_ANON_KEY\"" > "$(dirname "$0")/../config.js"
echo "config.js generado"
