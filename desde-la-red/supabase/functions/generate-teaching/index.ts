// supabase/functions/generate-teaching/index.ts
//
// Escribe el borrador de una enseñanza con Claude, a partir de un tema que
// da la administradora. No publica nada: el Panel recibe el texto, lo pone
// en el formulario, y desde ahí se revisa y se guarda como cualquier otra.
//
// Solo para administradoras — lo comprueba is_admin() con la sesión de quien
// llama, no con ningún secreto compartido. Sin eso, cualquiera con la app
// abierta podría gastar la cuenta de Anthropic de la Red.

import Anthropic from "npm:@anthropic-ai/sdk@0.125.0";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const THEMES = [
  "Silencio", "Luz", "Sombra", "Umbral", "Raíz", "Respiración", "Fuego", "Retorno",
];

const BLOCK_KINDS = new Set(["paragraph", "verse", "subtitle"]);

interface TeachingDraft {
  title: string;
  subtitle: string;
  excerpt: string;
  tags: string[];
  body: { kind: "paragraph" | "verse" | "subtitle"; text: string }[];
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

/**
 * Claude a veces envuelve el JSON en una frase o en un bloque ```json```.
 * Se recorta a lo que hay entre la primera { y la última }, y se valida
 * campo por campo: nada se guarda si el resultado no tiene la forma de una
 * enseñanza de verdad.
 */
function parseTeachingJson(raw: string): TeachingDraft | null {
  const start = raw.indexOf("{");
  const end = raw.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) return null;

  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(raw.slice(start, end + 1));
  } catch {
    return null;
  }

  if (typeof obj.title !== "string" || !obj.title.trim()) return null;
  if (!Array.isArray(obj.body)) return null;

  const body = (obj.body as unknown[])
    .filter(
      (b): b is { kind?: unknown; text?: unknown } =>
        !!b && typeof b === "object" && typeof (b as { text?: unknown }).text === "string",
    )
    .map((b) => ({
      kind: (BLOCK_KINDS.has(String(b.kind)) ? b.kind : "paragraph") as
        | "paragraph"
        | "verse"
        | "subtitle",
      text: String(b.text).trim(),
    }))
    .filter((b) => b.text.length > 0);

  if (body.length === 0) return null;

  return {
    title: String(obj.title).trim(),
    subtitle: typeof obj.subtitle === "string" ? obj.subtitle.trim() : "",
    excerpt: typeof obj.excerpt === "string" ? obj.excerpt.trim() : "",
    tags: Array.isArray(obj.tags)
      ? (obj.tags as unknown[]).filter((t): t is string => typeof t === "string").slice(0, 5)
      : [],
    body,
  };
}

const SYSTEM_PROMPT = `Escribes enseñanzas para "Desde la Red", una app de acompañamiento
espiritual y bienestar. El tono es cálido, concreto y sin clichés de
autoayuda: nada de "el universo conspira a tu favor" ni frases de calendario.
Se parece más a alguien que ha pensado el tema de verdad y te lo cuenta con
calma, con imágenes precisas en vez de abstracciones.

Responde ÚNICAMENTE con un objeto JSON, sin texto antes ni después, sin
bloques de código y sin explicaciones. Forma exacta:

{
  "title": "string — el título de la enseñanza",
  "subtitle": "string — una frase que la resume, no repite el título",
  "excerpt": "string — dos o tres frases, lo que se lee en las tarjetas",
  "tags": ["dos a cuatro palabras sueltas, en minúscula"],
  "body": [
    { "kind": "paragraph", "text": "un párrafo de tres a cinco frases" },
    { "kind": "verse", "text": "una o dos líneas cortas, separadas por \\n, sin punto final" },
    { "kind": "subtitle", "text": "una frase corta que marca un giro en la lectura" }
  ]
}

Reglas del cuerpo:
- Entre cinco y ocho bloques, casi todos "paragraph".
- Como máximo dos "verse" y un "subtitle" en toda la pieza.
- Nunca empieces ni termines con "verse".
- Todo en español de España o Latinoamérica neutro, sin emojis, sin markdown.`;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "Método no permitido." }, 405);

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ error: "Falta sesión." }, 401);

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!supabaseUrl || !supabaseAnonKey) {
      return json({ error: "El proyecto no está configurado del todo." }, 500);
    }

    // Cliente con la sesión de quien llama: is_admin() responde por ella,
    // nunca por un secreto que viajara en la petición.
    const supabase = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: isAdmin, error: adminError } = await supabase.rpc("is_admin");
    if (adminError) return json({ error: "No se pudo comprobar tu cuenta." }, 500);
    if (!isAdmin) return json({ error: "Esto es solo para administradoras." }, 403);

    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!anthropicKey) {
      return json({
        error: "Falta la llave de Anthropic. Ponla en Edge Functions → Secrets como ANTHROPIC_API_KEY.",
      }, 500);
    }

    const payload = await req.json().catch(() => null) as
      | { topic?: unknown; theme?: unknown; guideName?: unknown }
      | null;

    const topic = typeof payload?.topic === "string" ? payload.topic.trim() : "";
    if (!topic) return json({ error: "Escribe sobre qué quieres que escriba." }, 400);
    if (topic.length > 300) {
      return json({ error: "Ese tema es demasiado largo. Resúmelo en una línea." }, 400);
    }

    const theme = typeof payload?.theme === "string" && THEMES.includes(payload.theme)
      ? payload.theme
      : "Silencio";
    const guideName = typeof payload?.guideName === "string" ? payload.guideName.trim() : "";

    const userMessage = [
      `Tema o palabras clave: ${topic}`,
      `Hilo de la app en el que entra: ${theme}`,
      guideName ? `La firma ${guideName} — su voz puede colarse en el tono, sin exagerar.` : "",
    ].filter(Boolean).join("\n");

    const anthropic = new Anthropic({ apiKey: anthropicKey });

    const response = await anthropic.messages.create({
      model: "claude-opus-5",
      max_tokens: 4096,
      system: SYSTEM_PROMPT,
      output_config: { effort: "medium" },
      messages: [{ role: "user", content: userMessage }],
    });

    const textBlock = response.content.find(
      (b): b is { type: "text"; text: string } => b.type === "text",
    );
    const draft = textBlock ? parseTeachingJson(textBlock.text) : null;

    if (!draft) {
      return json({
        error: "La respuesta no vino en el formato esperado. Inténtalo otra vez.",
      }, 502);
    }

    return json({ teaching: draft });
  } catch (e) {
    console.error("generate-teaching:", e);
    return json({ error: "Algo salió mal generando la enseñanza." }, 500);
  }
});
