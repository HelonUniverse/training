import { useRouter } from 'expo-router';
import React, { useMemo, useState } from 'react';
import { ScrollView, StyleSheet, Text, View } from 'react-native';

import { Chip } from '@/components/Chip';
import { GuideCard } from '@/components/GuideCard';
import { Screen } from '@/components/Screen';
import { ScreenHeader } from '@/components/ScreenHeader';
import { SearchField } from '@/components/SearchField';
import { matches } from '@/lib/format';
import { useContent } from '@/store/content';
import { colors, fonts, glowText, screenPadding, spacing } from '@/theme';

/** Pantalla 9 — Guías de la Red. */
export default function GuiasScreen() {
  const { guides } = useContent();
  const router = useRouter();
  const [query, setQuery] = useState('');
  const [approach, setApproach] = useState<string | null>(null);

  const approaches = useMemo(
    () => Array.from(new Set(guides.flatMap((g) => g.approach))),
    [guides],
  );

  const results = useMemo(
    () =>
      guides.filter((g) => {
        if (approach && !g.approach.includes(approach)) return false;
        return matches(query, g.name, g.title, g.location, ...g.approach, ...g.languages);
      }),
    [guides, query, approach],
  );

  return (
    <Screen padded={false} header={<ScreenHeader title="Guías de la Red" />}>
      <View style={styles.head}>
        <Text style={styles.title}>Quién puede{'\n'}acompañarte</Text>
        <Text style={styles.lead}>
          {guides.length} guías en la Red. Cada una con su propia forma de escuchar.
        </Text>
      </View>

      <View style={styles.searchBox}>
        <SearchField
          value={query}
          onChangeText={setQuery}
          placeholder="Buscar por nombre, lugar o práctica…"
        />
      </View>

      <ScrollView
        horizontal
        showsHorizontalScrollIndicator={false}
        contentContainerStyle={styles.chipRow}
      >
        <Chip label="Todas" selected={approach === null} onPress={() => setApproach(null)} />
        {approaches.map((a) => (
          <Chip
            key={a}
            label={a}
            selected={approach === a}
            onPress={() => setApproach(approach === a ? null : a)}
          />
        ))}
      </ScrollView>

      <View style={styles.list}>
        {results.length === 0 ? (
          <Text style={styles.empty}>Ninguna guía coincide con esa búsqueda.</Text>
        ) : (
          results.map((g) => (
            <GuideCard key={g.id} guide={g} onPress={() => router.push(`/guias/${g.id}`)} />
          ))
        )}
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  head: { paddingHorizontal: screenPadding, gap: 10, marginBottom: spacing.xl },
  title: {
    ...glowText,
    fontFamily: fonts.displayLight,
    fontSize: 36,
    lineHeight: 42,
    color: colors.text,
  },
  lead: {
    fontFamily: fonts.body,
    fontSize: 13.5,
    lineHeight: 21,
    color: colors.textSoft,
  },
  searchBox: { paddingHorizontal: screenPadding, marginBottom: spacing.lg },
  chipRow: { paddingHorizontal: screenPadding, gap: spacing.sm, paddingBottom: spacing.xl },
  list: { paddingHorizontal: screenPadding, gap: spacing.md },
  empty: {
    fontFamily: fonts.body,
    fontSize: 13,
    color: colors.textMuted,
    textAlign: 'center',
    paddingVertical: spacing.xxl,
  },
});
