# Conectar la Red a Supabase

La app funciona hoy sin backend: si no hay variables de entorno, `isBackendConfigured`
es `false`, el contenido sale del paquete local y las marcas se guardan con
AsyncStorage. Nada de lo que sigue puede romper lo que ya está en vivo.

Cuando existan las dos variables, la app cambia sola: cuentas reales, contenido de
la base de datos y el camino de cada persona sincronizado entre dispositivos.

## 1 · Crear el proyecto

En https://supabase.com/dashboard → **New project**.

- Nombre: `desde-la-red`
- Región: `us-east-1` (la más cercana a Puerto Rico y República Dominicana)
- Guarda la contraseña de la base de datos donde puedas recuperarla

Un proyecto extra en una organización **Pro** consume cómputo aparte: son unos
**$10/mes**. Para no pagarlos, crea el proyecto en una organización nueva en plan
**Free** (el primer proyecto de cada organización Free no cuesta nada; se pausa
sola si nadie la usa durante una semana y se despierta con un clic).

## 2 · Aplicar el esquema

En el proyecto → **SQL Editor** → pegar `supabase/instalar.sql` entero y ejecutar.
Trae dentro las tres migraciones en orden y se puede correr dos veces sin duplicar
nada:

1. `0001_schema.sql` — tablas, permisos por fila y el disparador que crea el perfil
   al registrarse.
2. `0002_seed.sql` — las 8 enseñanzas, 5 guías, 10 servicios, 3 círculos,
   4 encuentros y 5 voces con las que nace la Red.
3. `0003_admin_lectura.sql` — deja que las administradoras lean las reservas de
   todo el mundo, para el panel.

Las migraciones son la fuente; `instalar.sql` se regenera con `npm run sql`.

Para regenerar el segundo archivo desde el contenido de `src/data/`:

```bash
npm run seed
```

## 3 · Las llaves

En **Project Settings → API** copia:

- `Project URL`
- `anon` / `publishable key` (es pública: puede vivir en el cliente)

Localmente, `desde-la-red/.env`:

```
EXPO_PUBLIC_SUPABASE_URL=https://xxxxxxxx.supabase.co
EXPO_PUBLIC_SUPABASE_ANON_KEY=eyJ...
```

En Vercel → proyecto `desde-la-red` → **Settings → Environment Variables**, las
mismas dos, en Production y Preview. Después, **Redeploy**.

> `.env` está en `.gitignore`. La llave `service_role` no entra nunca en la app.

## 4 · Confirmación de correo

En **Authentication → Providers → Email**:

- Para abrir la Red sin fricción: apaga *Confirm email*.
- Si la dejas encendida, la pantalla de registro ya muestra el aviso de revisar el
  correo; la persona entra al confirmar.

## 5 · Nombrar a las administradoras

Cada quien se registra primero desde la app. Después, en el SQL Editor:

```sql
update public.profiles
set role = 'admin'
where email = 'admin@heloniuminnovation.com';
```

Con eso, esa persona ve el **Panel** en su Perfil: escribe y publica enseñanzas,
da de alta guías, abre encuentros en vivo, pone servicios a reservar, ve quién
está en la Red (y asciende o retira administradoras) y lee las reservas que
llegan — todo sin tocar código. Los permisos los hace cumplir la base, no la
interfaz: aunque alguien sin rol llegue a una ruta `/admin/...` a mano, Postgres
rechaza cualquier escritura.

Lo que el panel todavía no edita —círculos y las preguntas de Mi Camino— se
cambia desde el editor de SQL.

## 6 · Escribir enseñanzas con IA (opcional)

Dentro del editor de una enseñanza hay un cuadro **Generar con IA**: se le da un
tema y Claude escribe el título, el resumen, las etiquetas y el cuerpo. No
publica nada sola — lo deja en el formulario para revisar y ajustar antes de
guardar, igual que si lo hubiera escrito una persona.

Esto corre en una función de Supabase (`generate-teaching`), no en la app, porque
ahí es donde puede vivir la llave de Anthropic sin exponerla al público. Para
encenderlo:

1. Consigue una llave en **console.anthropic.com → API Keys** (empieza por `sk-ant-`)
2. En el proyecto de Supabase → **Edge Functions → generate-teaching → Secrets**
   → añade `ANTHROPIC_API_KEY` con esa llave
3. Ya está — el botón funciona en cuanto guardes el secreto, sin volver a desplegar nada

Solo lo puede usar quien tenga rol de administradora: la función comprueba
`is_admin()` con la sesión de quien llama, igual que el resto del Panel. Cada
enseñanza generada cuesta unos centavos de dólar (modelo Claude Opus 5); sin la
llave puesta, el botón avisa con claridad en vez de fallar en silencio.

## Qué guarda cada tabla

| Contenido | Personal |
| --- | --- |
| `guides`, `teachings`, `services` | `saved_teachings`, `read_teachings` |
| `circles`, `live_events` | `circle_members`, `post_resonances` |
| `posts`, `path_questions` | `path_answers`, `bookings` |

Lo de la izquierda lo lee cualquiera y solo lo escriben las administradoras. Lo de
la derecha vive detrás de `auth.uid()`: nadie ve el camino de nadie más.
