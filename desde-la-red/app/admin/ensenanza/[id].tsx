import { Feather } from '@expo/vector-icons';
import { useLocalSearchParams, useRouter } from 'expo-router';
import React, { useMemo, useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { Card } from '@/components/Card';
import { Field, Options, SwitchRow, Tags } from '@/components/Form';
import { Screen } from '@/components/Screen';
import { ScreenHeader } from '@/components/ScreenHeader';
import { useToast } from '@/components/Toast';
import { deleteTeaching, generateTeaching, saveTeaching, slugify } from '@/data/admin';
import { images, type ImageKey } from '@/data/images';
import type { Teaching, TeachingBlock, TeachingTheme } from '@/data/types';
import * as haptics from '@/lib/haptics';
import { useApp } from '@/store/app-store';
import { useContent } from '@/store/content';
import { colors, fonts, glowText, radius, screenPadding, spacing } from '@/theme';

const THEMES: TeachingTheme[] = [
  'Silencio', 'Luz', 'Sombra', 'Umbral', 'Raíz', 'Respiración', 'Fuego', 'Retorno',
];

const TEACHING_IMAGES = (Object.keys(images) as ImageKey[]).filter((k) =>
  k.startsWith('teaching-'),
);

/** Las imágenes se eligen por lo que evocan, no por el nombre del archivo. */
const IMAGE_LABEL: Record<string, string> = {
  'teaching-silence': 'Silencio',
  'teaching-light': 'Luz',
  'teaching-water': 'Agua',
  'teaching-threshold': 'Umbral',
  'teaching-roots': 'Raíz',
  'teaching-breath': 'Aliento',
  'teaching-fire': 'Fuego',
  'teaching-return': 'Retorno',
};

const BLOCK_LABEL: Record<TeachingBlock['kind'], string> = {
  paragraph: 'Párrafo',
  subtitle: 'Subtítulo',
  verse: 'Verso',
};

const EMPTY: Teaching = {
  id: '',
  title: '',
  subtitle: '',
  theme: 'Silencio',
  image: 'teaching-silence',
  authorId: '',
  readMinutes: 5,
  listenMinutes: 6,
  publishedOn: 'Hoy',
  excerpt: '',
  body: [{ kind: 'paragraph', text: '' }],
  tags: [],
  featured: false,
};

/** Pantalla 16 — Escribir una enseñanza. */
export default function EnsenanzaEditorScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const toast = useToast();
  const { state } = useApp();
  const { findTeaching, guides, refresh } = useContent();

  const isNew = id === 'nueva';
  const existing = isNew ? undefined : findTeaching(id);

  const [draft, setDraft] = useState<Teaching>(
    () => existing ?? { ...EMPTY, authorId: guides[0]?.id ?? '' },
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [aiTopic, setAiTopic] = useState('');
  const [generating, setGenerating] = useState(false);
  const [aiError, setAiError] = useState<string | null>(null);

  const set = <K extends keyof Teaching>(key: K, value: Teaching[K]) =>
    setDraft((d) => ({ ...d, [key]: value }));

  const setBlock = (i: number, patch: Partial<TeachingBlock>) =>
    setDraft((d) => ({
      ...d,
      body: d.body.map((b, j) => (i === j ? { ...b, ...patch } : b)),
    }));

  const addBlock = (kind: TeachingBlock['kind']) => {
    haptics.tap();
    setDraft((d) => ({ ...d, body: [...d.body, { kind, text: '' }] }));
  };

  const removeBlock = (i: number) => {
    haptics.tap();
    setDraft((d) => ({ ...d, body: d.body.filter((_, j) => j !== i) }));
  };

  const moveBlock = (i: number, dir: -1 | 1) => {
    const j = i + dir;
    if (j < 0 || j >= draft.body.length) return;
    haptics.select();
    setDraft((d) => {
      const body = [...d.body];
      [body[i], body[j]] = [body[j], body[i]];
      return { ...d, body };
    });
  };

  const generate = async () => {
    if (generating || !aiTopic.trim()) return;
    haptics.tap();
    setGenerating(true);
    setAiError(null);

    const guideName = guides.find((g) => g.id === draft.authorId)?.name;
    const result = await generateTeaching({ topic: aiTopic.trim(), theme: draft.theme, guideName });
    setGenerating(false);

    if (!result.ok || !result.teaching) {
      setAiError(result.message ?? 'No se pudo generar la enseñanza.');
      haptics.warn();
      return;
    }

    const { title, subtitle, excerpt, tags, body } = result.teaching;
    const words = body.reduce((n, b) => n + b.text.split(/\s+/).filter(Boolean).length, 0);

    setDraft((d) => ({
      ...d,
      title,
      subtitle,
      excerpt,
      tags: tags.length ? tags : d.tags,
      body,
      // Minutos de lectura y de audio a partir de lo que escribió: ~200 y
      // ~150 palabras por minuto. Quedan como punto de partida — se editan
      // igual que cualquier otro campo.
      readMinutes: Math.max(2, Math.round(words / 200)),
      listenMinutes: Math.max(2, Math.round(words / 150)),
    }));
    haptics.success();
    toast({ text: 'Borrador listo — revísalo antes de publicar', icon: 'zap' });
  };

  const problems = useMemo(() => {
    const list: string[] = [];
    if (!draft.title.trim()) list.push('Falta el título.');
    if (!draft.authorId) list.push('Elige quién la firma.');
    if (!draft.excerpt.trim()) list.push('Falta el resumen que se ve en las tarjetas.');
    if (!draft.body.some((b) => b.text.trim())) list.push('El cuerpo está vacío.');
    return list;
  }, [draft]);

  const save = async () => {
    if (problems.length) {
      setError(problems[0]);
      haptics.warn();
      return;
    }
    setError(null);
    setBusy(true);
    const teaching: Teaching = {
      ...draft,
      id: draft.id || slugify(draft.title, 't'),
      body: draft.body.filter((b) => b.text.trim()),
    };
    const result = await saveTeaching(teaching);
    setBusy(false);

    if (!result.ok) {
      setError(result.message ?? 'No se pudo guardar.');
      haptics.warn();
      return;
    }
    await refresh();
    haptics.success();
    toast({ text: isNew ? 'Publicada en la Red' : 'Cambios guardados', icon: 'check' });
    router.back();
  };

  const remove = async () => {
    setBusy(true);
    const result = await deleteTeaching(draft.id);
    setBusy(false);
    if (!result.ok) {
      setError(result.message ?? 'No se pudo borrar.');
      return;
    }
    await refresh();
    toast({ text: 'Enseñanza retirada', icon: 'trash-2' });
    router.back();
  };

  if (state.user?.role !== 'admin') {
    return (
      <Screen header={<ScreenHeader title="Enseñanza" />}>
        <Text style={styles.denied}>Esta pantalla es para administradoras.</Text>
      </Screen>
    );
  }

  return (
    <Screen padded={false} header={<ScreenHeader title={isNew ? 'Nueva enseñanza' : 'Editar'} />}>
      <View style={styles.head}>
        <Text style={styles.title}>{isNew ? 'Escribe para\nla Red' : draft.title || 'Sin título'}</Text>
      </View>

      <View style={styles.section}>
        <Card glow accent="glow">
          <View style={styles.aiHeader}>
            <Feather name="zap" size={14} color={colors.glow} />
            <Text style={styles.aiTitle}>Generar con IA</Text>
          </View>
          <Text style={styles.aiHelp}>
            Dale un tema o unas palabras clave y Claude escribe el título, el resumen y el
            cuerpo. Nada se publica solo: revisa y ajusta antes de guardar.
          </Text>
          <View style={styles.aiRow}>
            <Field
              label=""
              value={aiTopic}
              onChangeText={setAiTopic}
              placeholder="Sobre soltar el control, por ejemplo"
              editable={!generating}
              style={styles.aiField}
            />
            <Button
              label={generating ? 'Escribiendo…' : 'Generar'}
              icon="zap"
              size="md"
              loading={generating}
              disabled={generating || !aiTopic.trim()}
              onPress={generate}
            />
          </View>
          {aiError ? (
            <Text style={styles.aiError}>{aiError}</Text>
          ) : draft.body.some((b) => b.text.trim()) ? (
            <Text style={styles.aiWarning}>
              Ya hay texto en el cuerpo — generar lo reemplaza entero.
            </Text>
          ) : null}
        </Card>
      </View>

      <View style={styles.form}>
        <Field
          label="Título"
          value={draft.title}
          onChangeText={(v) => set('title', v)}
          placeholder="El silencio también es una respuesta"
        />
        <Field
          label="Subtítulo"
          value={draft.subtitle}
          onChangeText={(v) => set('subtitle', v)}
          placeholder="La línea que explica de qué va"
          multiline
          minHeight={72}
        />
        <Field
          label="Resumen"
          value={draft.excerpt}
          onChangeText={(v) => set('excerpt', v)}
          placeholder="Dos o tres líneas: es lo que se lee en las tarjetas y en Hoy."
          multiline
          minHeight={96}
          helper="Aparece en la Biblioteca Viva y en la pantalla de Hoy."
        />

        <Options
          label="Tema"
          value={draft.theme}
          options={THEMES}
          onChange={(v) => set('theme', v)}
        />

        <Options
          label="Firma"
          value={draft.authorId}
          options={guides.map((g) => g.id)}
          labelOf={(gid) => guides.find((g) => g.id === gid)?.name ?? gid}
          onChange={(v) => set('authorId', v)}
          helper="Quién la escribe. Las guías se dan de alta en el panel."
        />

        <Options
          label="Imagen"
          value={draft.image}
          options={TEACHING_IMAGES}
          labelOf={(k) => IMAGE_LABEL[k] ?? k.replace('teaching-', '')}
          onChange={(v) => set('image', v)}
        />

        <View style={styles.pair}>
          <Field
            label="Minutos de lectura"
            value={String(draft.readMinutes)}
            onChangeText={(v) => set('readMinutes', Number(v.replace(/[^0-9]/g, '')) || 0)}
            keyboardType="numeric"
            style={styles.pairItem}
          />
          <Field
            label="Minutos de audio"
            value={String(draft.listenMinutes)}
            onChangeText={(v) => set('listenMinutes', Number(v.replace(/[^0-9]/g, '')) || 0)}
            keyboardType="numeric"
            style={styles.pairItem}
          />
        </View>

        <Field
          label="Cuándo se publicó"
          value={draft.publishedOn}
          onChangeText={(v) => set('publishedOn', v)}
          placeholder="Hoy · Ayer · Hace 3 días"
          helper="Se muestra tal cual, con las palabras que escribas."
        />

        <Tags
          label="Etiquetas"
          values={draft.tags}
          onChange={(v) => set('tags', v)}
          placeholder="contemplación"
          helper="Ayudan a que la busquen."
        />

        <SwitchRow
          label="Enseñanza de hoy"
          helper="La que abre la app. Solo una a la vez: al marcarla, quita la marca de la anterior."
          value={!!draft.featured}
          onChange={(v) => set('featured', v)}
        />
      </View>

      <View style={styles.bodySection}>
        <Text style={styles.bodyHeading}>El cuerpo</Text>
        <Text style={styles.bodyHelp}>
          Los versos se componen centrados y en cursiva; los subtítulos parten la lectura.
        </Text>

        <View style={styles.blocks}>
          {draft.body.map((block, i) => (
            <View key={i} style={styles.block}>
              <View style={styles.blockBar}>
                <Text style={styles.blockKind}>{BLOCK_LABEL[block.kind]}</Text>
                <View style={styles.blockActions}>
                  <IconButton icon="arrow-up" label="Subir" onPress={() => moveBlock(i, -1)} />
                  <IconButton icon="arrow-down" label="Bajar" onPress={() => moveBlock(i, 1)} />
                  <IconButton icon="trash-2" label="Quitar" onPress={() => removeBlock(i)} />
                </View>
              </View>
              <Field
                label=""
                value={block.text}
                onChangeText={(v) => setBlock(i, { text: v })}
                placeholder={
                  block.kind === 'verse'
                    ? 'Dos líneas que respiren'
                    : block.kind === 'subtitle'
                      ? 'La idea que viene ahora'
                      : 'Escribe aquí'
                }
                multiline
                minHeight={block.kind === 'paragraph' ? 120 : 72}
              />
            </View>
          ))}
        </View>

        <View style={styles.addRow}>
          <Button label="Párrafo" variant="outline" size="sm" icon="plus" onPress={() => addBlock('paragraph')} />
          <Button label="Subtítulo" variant="outline" size="sm" icon="plus" onPress={() => addBlock('subtitle')} />
          <Button label="Verso" variant="outline" size="sm" icon="plus" onPress={() => addBlock('verse')} />
        </View>
      </View>

      <View style={styles.footer}>
        {error ? (
          <Card>
            <Text style={styles.error}>{error}</Text>
          </Card>
        ) : null}

        <Button
          label={isNew ? 'Publicar en la Red' : 'Guardar cambios'}
          size="lg"
          full
          loading={busy}
          disabled={busy}
          onPress={save}
        />

        {!isNew ? (
          <Button
            label="Retirar de la Red"
            variant="ghost"
            size="sm"
            icon="trash-2"
            disabled={busy}
            onPress={remove}
          />
        ) : null}
      </View>
    </Screen>
  );
}

function IconButton({
  icon,
  label,
  onPress,
}: {
  icon: keyof typeof Feather.glyphMap;
  label: string;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      onPress={onPress}
      hitSlop={6}
      style={({ pressed }) => [styles.iconButton, pressed && { opacity: 0.6 }]}
    >
      <Feather name={icon} size={13} color={colors.textMuted} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  head: { paddingHorizontal: screenPadding, marginBottom: spacing.xl },
  title: { ...glowText, fontFamily: fonts.displayLight, fontSize: 29, lineHeight: 37, color: colors.text },

  section: { paddingHorizontal: screenPadding, marginBottom: spacing.xl },
  aiHeader: { flexDirection: 'row', alignItems: 'center', gap: 8, marginBottom: 6 },
  aiTitle: { fontFamily: fonts.displaySemi, fontSize: 15, color: colors.text },
  aiHelp: { fontFamily: fonts.body, fontSize: 12.5, lineHeight: 19, color: colors.textMuted },
  aiRow: { flexDirection: 'row', alignItems: 'flex-end', gap: 10, marginTop: spacing.md },
  aiField: { flex: 1 },
  aiWarning: {
    fontFamily: fonts.body,
    fontSize: 11.5,
    color: colors.textMuted,
    marginTop: spacing.sm,
  },
  aiError: {
    fontFamily: fonts.body,
    fontSize: 12,
    lineHeight: 17,
    color: colors.live,
    marginTop: spacing.sm,
  },

  form: { paddingHorizontal: screenPadding, gap: spacing.lg, marginBottom: spacing.xxl },
  pair: { flexDirection: 'row', gap: 12 },
  pairItem: { flex: 1 },

  bodySection: { paddingHorizontal: screenPadding, gap: 8, marginBottom: spacing.xxl },
  bodyHeading: { fontFamily: fonts.display, fontSize: 21, color: colors.text },
  bodyHelp: { fontFamily: fonts.body, fontSize: 12.5, lineHeight: 19, color: colors.textMuted },
  blocks: { gap: 14, marginTop: spacing.md },
  block: {
    gap: 10,
    padding: 14,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surfaceSunken,
  },
  blockBar: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  blockKind: {
    fontFamily: fonts.bodyMedium,
    fontSize: 10.5,
    letterSpacing: 1.8,
    textTransform: 'uppercase',
    color: colors.cyan,
  },
  blockActions: { flexDirection: 'row', gap: 6 },
  iconButton: {
    width: 30,
    height: 30,
    borderRadius: 9,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
  },
  addRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: spacing.md },

  footer: { paddingHorizontal: screenPadding, gap: spacing.md },
  error: { fontFamily: fonts.body, fontSize: 13, lineHeight: 20, color: colors.live },
  denied: { fontFamily: fonts.body, fontSize: 14, color: colors.textMuted },
});
