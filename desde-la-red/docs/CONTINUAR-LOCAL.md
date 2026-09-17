# Seguir el proyecto en tu computadora con Claude Code

Todo lo que necesitas para dejar de trabajar aquí y seguir en tu propia
máquina, con Claude Code abierto directamente sobre el código.

## 1 · Instalar Claude Code (una sola vez)

Necesitas [Node.js](https://nodejs.org) 18 o más nuevo instalado. Después, en
una terminal:

```bash
npm install -g @anthropic-ai/claude-code
```

Verifica que quedó instalado:

```bash
claude --version
```

(Si el comando no existe o algo cambió, la instalación oficial siempre está en
**claude.com/code**.)

## 2 · Traerte el proyecto

```bash
git clone https://github.com/HelonUniverse/training.git
cd training/desde-la-red
npm install
```

Todo el código de Desde la Red vive dentro de esa carpeta `desde-la-red/`
—el repositorio `training` es más grande, pero la app es esa subcarpeta.

## 3 · Abrir Claude Code ahí mismo

Desde dentro de `desde-la-red/`:

```bash
claude
```

Eso abre una sesión de Claude Code con el código del proyecto delante — puede
leerlo, editarlo, correr comandos, todo igual que aquí. La primera vez te va a
pedir iniciar sesión con tu cuenta de Claude.

## 4 · Correr la app

```bash
npm run web
```

Abre una pestaña con la app corriendo en el navegador. Para probarla en el
teléfono en vez del navegador: `npm start` y escanea el código QR con la app
Expo Go.

**Importante:** la app local habla con la **misma base de datos real** que ya
está en producción (el proyecto de Supabase `desde-la-red`, en tu
organización "Desde la Red"). No es una copia de prueba — cualquier cosa que
guardes o borres desde tu computadora, incluido el Panel de administración,
cambia lo que ve todo el mundo en `desde-la-red.vercel.app`.

## 5 · Otros comandos del proyecto

| Comando | Qué hace |
| --- | --- |
| `npm run typecheck` | Revisa que TypeScript no tenga errores |
| `npm run build:web` | Genera la carpeta `dist/` lista para publicar (es lo que corre Vercel solo, no hace falta a mano) |
| `npm run seed` | Regenera `supabase/migrations/0002_seed.sql` a partir de `src/data/` |
| `npm run sql` | Junta las migraciones en `supabase/instalar.sql` |

## 6 · Dónde vive cada pieza

| Pieza | Dónde |
| --- | --- |
| Código | github.com/HelonUniverse/training, rama `main` |
| App en vivo | https://desde-la-red.vercel.app — se despliega sola con cada push a `main` |
| Base de datos | Supabase, proyecto `desde-la-red` (organización "Desde la Red", plan Free) |
| Tu cuenta de administradora | carlamelendez19@gmail.com |
| Generador de enseñanzas con IA | función `generate-teaching` en Supabase — necesita el secreto `ANTHROPIC_API_KEY` (ver `docs/SUPABASE.md`) |

`docs/SUPABASE.md` tiene el resto: cómo instalar el esquema, dar de alta
administradoras, y encender el generador de enseñanzas con IA.

## 7 · Guardar tus cambios

Igual que aquí: Claude Code puede hacer el `git add` / `commit` / `push` por
ti, o lo haces tú a mano. Como `main` recibe despliegue automático, cualquier
push ahí sale a producción en un par de minutos.
