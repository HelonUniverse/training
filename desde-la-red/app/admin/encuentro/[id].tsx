import { useLocalSearchParams, useRouter } from 'expo-router';
import React, { useMemo, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { Card } from '@/components/Card';
import { Field, Options } from '@/components/Form';
import { Screen } from '@/components/Screen';
import { ScreenHeader } from '@/components/ScreenHeader';
import { useToast } from '@/components/Toast';
import { deleteLiveEvent, saveLiveEvent, slugify } from '@/data/admin';
import { images, type ImageKey } from '@/data/images';
import type { LiveEvent } from '@/data/types';
import * as haptics from '@/lib/haptics';
import { useApp } from '@/store/app-store';
import { useContent } from '@/store/content';
import { colors, fonts, glowText, screenPadding, spacing } from '@/theme';

const STATUS: LiveEvent['status'][] = ['live', 'soon', 'scheduled'];
const STATUS_LABEL: Record<LiveEvent['status'], string> = {
  live: 'En vivo ahora',
  soon: 'Empieza pronto',
  scheduled: 'Agendado',
};

/** Las imágenes que encajan con un encuentro. */
const EVENT_IMAGES = (Object.keys(images) as ImageKey[]).filter(
  (k) => k.startsWith('live-') || k.startsWith('circle-'),
);
const IMAGE_LABEL: Record<string, string> = {
  'live-ceremony': 'Ceremonia',
  'live-meditation': 'Meditación',
  'circle-luna': 'Luna',
  'circle-fuego': 'Fuego',
  'circle-raiz': 'Raíz',
};

const EMPTY: LiveEvent = {
  id: '',
  title: '',
  guideId: '',
  image: 'live-ceremony',
  startsAt: '',
  durationMinutes: 60,
  attendees: 0,
  status: 'scheduled',
  description: '',
};

/** Pantalla 19 — Abrir un encuentro en vivo. */
export default function EncuentroEditorScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const toast = useToast();
  const { state } = useApp();
  const { liveEvents, guides, refresh } = useContent();

  const isNew = id === 'nuevo';
  const existing = isNew ? undefined : liveEvents.find((e) => e.id === id);

  const [draft, setDraft] = useState<LiveEvent>(
    () => existing ?? { ...EMPTY, guideId: guides[0]?.id ?? '' },
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const set = <K extends keyof LiveEvent>(key: K, value: LiveEvent[K]) =>
    setDraft((d) => ({ ...d, [key]: value }));

  const problems = useMemo(() => {
    const list: string[] = [];
    if (!draft.title.trim()) list.push('Falta el título del encuentro.');
    if (!draft.startsAt.trim()) list.push('Falta cuándo empieza.');
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
    const result = await saveLiveEvent({ ...draft, id: draft.id || slugify(draft.title, 'e') });
    setBusy(false);

    if (!result.ok) {
      setError(result.message ?? 'No se pudo guardar.');
      haptics.warn();
      return;
    }
    await refresh();
    haptics.success();
    toast({ text: isNew ? 'Encuentro abierto' : 'Cambios guardados', icon: 'radio' });
    router.back();
  };

  const remove = async () => {
    setBusy(true);
    const result = await deleteLiveEvent(draft.id);
    setBusy(false);
    if (!result.ok) {
      setError(result.message ?? 'No se pudo borrar.');
      return;
    }
    await refresh();
    toast({ text: 'Encuentro cerrado', icon: 'trash-2' });
    router.back();
  };

  if (state.user?.role !== 'admin') {
    return (
      <Screen header={<ScreenHeader title="Encuentro" />}>
        <Text style={styles.denied}>Esta pantalla es para administradoras.</Text>
      </Screen>
    );
  }

  return (
    <Screen
      padded={false}
      header={<ScreenHeader title={isNew ? 'Nuevo encuentro' : 'Editar encuentro'} />}
    >
      <View style={styles.head}>
        <Text style={styles.title}>
          {isNew ? 'Abre una sala\nen vivo' : draft.title || 'Sin título'}
        </Text>
      </View>

      <View style={styles.form}>
        <Field
          label="Título"
          value={draft.title}
          onChangeText={(v) => set('title', v)}
          placeholder="Ceremonia de luna: cerrar el ciclo"
        />
        <Field
          label="Cuándo empieza"
          value={draft.startsAt}
          onChangeText={(v) => set('startsAt', v)}
          placeholder="Hoy · 20:00"
          helper="Se muestra tal cual. «Hoy · 20:00», «Mañana · 07:30», «Jueves · 19:00»."
        />
        <Field
          label="De qué va"
          value={draft.description}
          onChangeText={(v) => set('description', v)}
          placeholder="Qué se va a hacer y qué hace falta traer."
          multiline
          minHeight={110}
        />

        <Options
          label="Estado"
          value={draft.status}
          options={STATUS}
          labelOf={(s) => STATUS_LABEL[s]}
          onChange={(v) => set('status', v)}
          helper="«En vivo ahora» lo pone arriba de todo con el punto rojo."
        />

        {guides.length > 0 ? (
          <Options
            label="Quién lo guía"
            value={draft.guideId}
            options={guides.map((g) => g.id)}
            labelOf={(gid) => guides.find((g) => g.id === gid)?.name ?? gid}
            onChange={(v) => set('guideId', v)}
          />
        ) : null}

        <Options
          label="Imagen"
          value={draft.image}
          options={EVENT_IMAGES}
          labelOf={(k) => IMAGE_LABEL[k] ?? k}
          onChange={(v) => set('image', v)}
        />

        <View style={styles.pair}>
          <Field
            label="Duración (min)"
            value={String(draft.durationMinutes)}
            onChangeText={(v) => set('durationMinutes', Number(v.replace(/[^0-9]/g, '')) || 0)}
            keyboardType="numeric"
            style={styles.pairItem}
          />
          <Field
            label="Apuntadas"
            value={String(draft.attendees)}
            onChangeText={(v) => set('attendees', Number(v.replace(/[^0-9]/g, '')) || 0)}
            keyboardType="numeric"
            style={styles.pairItem}
          />
        </View>
      </View>

      <View style={styles.footer}>
        {error ? (
          <Card>
            <Text style={styles.error}>{error}</Text>
          </Card>
        ) : null}

        <Button
          label={isNew ? 'Abrir el encuentro' : 'Guardar cambios'}
          size="lg"
          full
          loading={busy}
          disabled={busy}
          onPress={save}
        />

        {!isNew ? (
          <Button
            label="Cerrar el encuentro"
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

const styles = StyleSheet.create({
  head: { paddingHorizontal: screenPadding, marginBottom: spacing.xl },
  title: {
    ...glowText,
    fontFamily: fonts.displayLight,
    fontSize: 29,
    lineHeight: 37,
    color: colors.text,
  },
  form: { paddingHorizontal: screenPadding, gap: spacing.lg, marginBottom: spacing.xxl },
  pair: { flexDirection: 'row', gap: 12 },
  pairItem: { flex: 1 },
  footer: { paddingHorizontal: screenPadding, gap: spacing.md },
  error: { fontFamily: fonts.body, fontSize: 13, lineHeight: 20, color: colors.live },
  denied: { fontFamily: fonts.body, fontSize: 14, color: colors.textMuted },
});
