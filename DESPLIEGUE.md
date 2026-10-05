# Carrito: despliegue, instalación en Android y pruebas

La app es un solo archivo (`carrito-supabase.html`) más los archivos de la PWA. No hay paso de compilación.

| Archivo | Para qué |
|---|---|
| `carrito-supabase.html` | La app |
| `schema.sql` | Base de datos, reglas de negocio y seguridad (Supabase) |
| `config.example.js` → `config.js` | URL y clave **anon** del proyecto. `config.js` **no** va a git |
| `manifest.webmanifest`, `sw.js`, `icons/` | Instalación en el celular y apertura sin conexión |
| `tests.js`, `tests/sql/`, `tests/mobile.js` | Pruebas |

## 1. Supabase

1. Creá un proyecto en <https://supabase.com>.
2. **SQL Editor → New query**: pegá todo `schema.sql` y ejecutalo. Se puede volver a ejecutar (por ejemplo al actualizar) sin perder datos.
3. **Authentication → Providers → Email**: activado. Dejá "Confirm email" activado si querés que se confirme el correo.
4. **Authentication → URL Configuration → Site URL**: la URL https donde vas a publicar la app (paso 3).
5. Registrá enseguida la cuenta del dueño: **el primer usuario que se registra queda ADMIN**. Los demás quedan OPERADOR inactivos hasta que un ADMIN los active en Config → Usuarios.
6. Cuando ya estén todas las cuentas, podés desactivar el registro: **Authentication → Sign In / Providers → Allow new users to sign up** (apagado).
7. **Project Settings → API**: copiá la *Project URL* y la clave **anon / publishable**. **Nunca** uses la clave `service_role` / `secret` en la app: la app se niega a arrancar si la detecta.

## 2. Configuración (fuera del repo)

Opción A, a mano: copiá `config.example.js` como `config.js` y completá `url` y `anonKey`.

Opción B, variables de entorno (Netlify, Vercel, Cloudflare Pages): definí `SUPABASE_URL` y `SUPABASE_ANON_KEY` en el panel del hosting y usá como comando de build:

```sh
sh scripts/make-config.sh
```

El script rechaza claves `service_role` o `sb_secret_`.

## 3. Publicar (HTTPS obligatorio)

El service worker y la instalación solo funcionan con HTTPS. Cualquier hosting estático sirve. Publicá estos archivos, de ser posible en un sitio propio para el carrito:

```
carrito-supabase.html  config.js  manifest.webmanifest  sw.js  icons/
```

- **Netlify / Cloudflare Pages**: conectá el repo, sin framework, build `sh scripts/make-config.sh`, carpeta de publicación `/`.
- **GitHub Pages**: no tiene variables de entorno, así que no sirve para generar `config.js`. Si lo usás, subí `config.js` solo a la rama publicada y nunca a `main`: la clave anon es pública, pero se mantiene fuera del código.

La dirección queda así: `https://TU-SITIO/carrito-supabase.html`.

## 4. Instalar en Android (PWA, sin tienda)

1. En el celular, abrí la URL en **Chrome** e ingresá.
2. Menú ⋮ → **Instalar app** (o "Agregar a pantalla principal").
3. Queda con ícono propio y se abre a pantalla completa. Si no hay conexión, muestra el último dato conocido en solo lectura con el aviso "Sin conexión: no se pueden cargar movimientos".

Para que una versión nueva llegue al celular, cerrá y volvé a abrir la app con conexión. La interfaz se pide primero a la red.

## 5. Empaquetar como APK/AAB (opcional, para Play Store)

Ninguno de estos pasos usa tus credenciales. La clave de firma la creás y la guardás vos. Los archivos `*.keystore`, `*.jks` y la carpeta `android/` están en `.gitignore`.

### Opción recomendada: Trusted Web Activity (Bubblewrap)

Usa el Chrome del teléfono, así que service worker, login y descargas funcionan igual que en la PWA.

1. Instalá Node 18 o superior y JDK 17. Después: `npm i -g @bubblewrap/cli`
2. En una carpeta **fuera** del repo: `bubblewrap init --manifest https://TU-SITIO/manifest.webmanifest`
   - Package ID: por ejemplo `ar.com.tucarrito.app`
   - Cuando pregunte por la clave de firma, que cree una nueva (`android.keystore`) y guardá la contraseña en un lugar seguro. Si perdés esa clave, no vas a poder actualizar la app en Play.
3. `bubblewrap build` genera `app-release-signed.apk` (para instalar directo) y `app-release-bundle.aab` (para Play Console).
4. Para quitar la barra de URL, verificá el dominio: `bubblewrap fingerprint generateAssetLinks` crea `assetlinks.json`. Publicalo en `https://TU-SITIO/.well-known/assetlinks.json`. Si usás Play App Signing, agregá también la huella SHA-256 que muestra Play Console (Configuración → Integridad de la app).
5. Para probar el APK: activá "Orígenes desconocidos" en el celular e instalalo, o usá `adb install app-release-signed.apk`.
6. Para publicar: en Play Console, Crear app → subí el `.aab` → completá la ficha → Prueba interna.

### Alternativa: Capacitor

1. En una carpeta fuera del repo: `npm init -y && npm i @capacitor/core @capacitor/cli @capacitor/android`
2. `npx cap init Carrito ar.com.tucarrito.app --web-dir www`
3. Copiá a `www/` los archivos de la sección 3, con `carrito-supabase.html` renombrado como `index.html`. El `start_url` de `manifest.webmanifest` no se usa en Capacitor.
4. `npx cap add android && npx cap copy && npx cap open android`. Se abre Android Studio.
5. Android Studio → Build → Generate Signed App Bundle / APK. Ahí creás tu propia clave.

Limitaciones de Capacitor: el WebView no descarga archivos por sí solo. Para exportar CSV, Excel o respaldo hacen falta los plugins `@capacitor/filesystem` y `@capacitor/share`. Por eso se recomienda TWA.

## 6. Pruebas

```sh
node tests.js                                       # lógica del navegador (A–J, validaciones, exportación, seguridad)
bash tests/sql/run.sh                               # schema.sql en un Postgres 16 vacío + reglas de la base + concurrencia real
NODE_PATH=$(npm root -g) node tests/mobile.js       # Chromium a 360×800 (necesita playwright)
```

`tests/sql` usa `tests/sql/supabase_stub.sql`, que imita roles, `auth.uid()`, Storage y la publicación Realtime de Supabase. No reemplaza una prueba en un proyecto Supabase real.

## Seguridad

- En el cliente solo va la clave anon. Todos los permisos los aplica la base: RLS, el trigger `records_guard` y las políticas de Storage.
- No se borra nada: solo hay borrado lógico (`deleted`). `DELETE` está revocado.
- Los comprobantes están en un bucket privado. Se ven solo con sesión activa, mediante una URL firmada que dura 60 s. Cada usuario sube únicamente a su propia carpeta.
- Si una clave secreta llegó a subirse a git, rotala en Supabase: borrarla del historial no alcanza.
