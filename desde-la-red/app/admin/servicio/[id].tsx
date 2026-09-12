import { useLocalSearchParams, useRouter } from 'expo-router';
import React, { useMemo, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { Card } from '@/components/Card';
import { Field, Options, Tags } from '@/components/Form';
import { Screen } from '@/components/Screen';
import { ScreenHeader } from '@/components/ScreenHeader';
import { useToast } from '@/components/Toast';
import { deleteService, saveService, slugify } from '@/data/admin';
import type { Service } from '@/data/types';
import * as haptics from '@/lib/haptics';
import { useApp } from '@/store/app-store';
import { useContent } from '@/store/content';
import { colors, fonts, glowText, screenPadding, spacing } from '@/theme';

const FORMATS: Service['format'][] = ['Individual', 'Círculo', 'Intensivo'];
const MODALITIES: Service['modality'][] = ['En línea', 'Presencial'];

const EMPTY: Service = {
  id: '',
  guideId: '',
  name: '',
  format: 'Individual',
  modality: 'En línea',
  durationMinutes: 60,
  price: 0,
  currency: 'USD',
  description: '',
  includes: [],
};

/** Pantalla 20 — Poner un servicio a reservar. */
export default function ServicioEditorScreen() {
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();
  const toast = useToast();
  const { state } = useApp();
  const { findService, guides, refresh } = useContent();

  const isNew = id === 'nuevo';
  const existing = isNew ? undefined : findService(id);

  const [draft, setDraft] = useState<Service>(
    () => existing ?? { ...EMPTY, guideId: guides[0]?.id ?? '' },
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const set = <K extends keyof Service>(key: K, value: Service[K]) =>
    setDraft((d) => ({ ...d, [key]: value }));

  const problems = useMemo(() => {
    const list: string[] = [];
    if (!draft.name.trim()) list.push('Falta el nombre del servicio.');
    if (!draft.guideId) list.push('Elige quién lo ofrece.');
    if (!draft.description.trim()) list.push('Falta explicar en qué consiste.');
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
    const result = await saveService({ ...draft, id: draft.id || slugify(draft.name, 's') });
    setBusy(false);

    if (!result.ok) {
      setError(result.message ?? 'No se pudo guardar.');
      haptics.warn();
      return;
    }
    await refresh();
    haptics.success();
    toast({ text: isNew ? 'Servicio disponible' : 'Cambios guardados', icon: 'check' });
    router.back();
  };

  const remove = async () => {
    setBusy(true);
    const result = await deleteService(draft.id);
    setBusy(false);
    if (!result.ok) {
      setError(result.message ?? 'No se pudo borrar.');
      return;
    }
    await refresh();
    toast({ text: 'Servicio retirado', icon: 'trash-2' });
    router.back();
  };

  if (state.user?.role !== 'admin') {
    return (
      <Screen header={<ScreenHeader title="Servicio" />}>
        <Text style={styles.denied}>Esta pantalla es para administradoras.</Text>
      </Screen>
    );
  }

  if (guides.length === 0) {
    return (
      <Screen header={<ScreenHeader title="Servicio" />}>
        <Card>
          <Text style={styles.noteTitle}>Primero hace falta una guía</Text>
          <Text style={styles.note}>
            Un servicio lo ofrece alguien. Da de alta una guía en el Panel y vuelve.
          </Text>
        </Card>
      </Screen>
    );
  }

  return (
    <Screen
      padded={false}
      header={<ScreenHeader title={isNew ? 'Nuevo servicio' : 'Editar servicio'} />}
    >
      <View style={styles.head}>
        <Text style={styles.title}>
          {isNew ? 'Algo que se\npueda reservar' : draft.name || 'Sin nombre'}
        </Text>
      </View>

      <View style={styles.form}>
        <Field
          label="Nombre"
          value={draft.name}
          onChangeText={(v) => set('name', v)}
          placeholder="Sesión de escucha profunda"
        />

        <Options
          label="Quién lo ofrece"
          value={draft.guideId}
          options={guides.map((g) => g.id)}
          labelOf={(gid) => guides.find((g) => g.id === gid)?.name ?? gid}
          onChange={(v) => set('guideId', v)}
        />

        <Field
          label="En qué consiste"
          value={draft.description}
          onChangeText={(v) => set('description', v)}
          placeholder="Qué pasa en ese encuentro y para quién es."
          multiline
          minHeight={120}
        />

        <Options
          label="Formato"
          value={draft.format}
          options={FORMATS}
          onChange={(v) => set('format', v)}
        />
        <Options
          label="Modalidad"
          value={draft.modality}
          options={MODALITIES}
          onChange={(v) => set('modality', v)}
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
            label="Precio (USD)"
            value={String(draft.price)}
            onChangeText={(v) => set('price', Number(v.replace(/[^0-9.]/g, '')) || 0)}
            keyboardType="numeric"
            style={styles.pairItem}
          />
        </View>

        <Tags
          label="Qué incluye"
          values={draft.includes}
          onChange={(v) => set('includes', v)}
          placeholder="Encuentro de 60 minutos"
          helper="Se listan en la ficha de reserva."
        />
      </View>

      <View style={styles.footer}>
        {error ? (
          <Card>
            <Text style={styles.error}>{error}</Text>
          </Card>
        ) : null}

        <Button
          label={isNew ? 'Ponerlo a reservar' : 'Guardar cambios'}
          size="lg"
          full
          loading={busy}
          disabled={busy}
          onPress={save}
        />

        {!isNew ? (
          <Button
            label="Retirar el servicio"
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
  noteTitle: { fontFamily: fonts.displaySemi, fontSize: 16, color: colors.text, marginBottom: 6 },
  note: { fontFamily: fonts.body, fontSize: 13, lineHeight: 20, color: colors.textMuted },
  denied: { fontFamily: fonts.body, fontSize: 14, color: colors.textMuted },
});
