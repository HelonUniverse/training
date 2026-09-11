import { Feather } from '@expo/vector-icons';
import { useLocalSearchParams, useRouter } from 'expo-router';
import React from 'react';
import { StyleSheet, Text, View } from 'react-native';

import { Avatar } from '@/components/Avatar';
import { Button } from '@/components/Button';
import { Card } from '@/components/Card';
import { Chip } from '@/components/Chip';
import { Screen } from '@/components/Screen';
import { ScreenHeader } from '@/components/ScreenHeader';
import { SectionHeader } from '@/components/SectionHeader';
import { ServiceCard } from '@/components/ServiceCard';
import { useContent } from '@/store/content';
import { colors, fonts, glowText, radius, screenPadding, spacing } from '@/theme';

/** Pantalla 10 — Perfil de Guía. */
export default function GuiaPerfilScreen() {
  const { circles, findGuide, servicesOfGuide, teachings } = useContent();
  const { id } = useLocalSearchParams<{ id: string }>();
  const router = useRouter();

  const guide = findGuide(id);

  if (!guide) {
    return (
      <Screen header={<ScreenHeader title="Guía" />}>
        <Text style={styles.empty}>Esta guía ya no está en la Red.</Text>
      </Screen>
    );
  }

  const guideServices = servicesOfGuide(guide.id);
  // Solo se enseña lo que se sabe. Una guía recién llegada no tiene años
  // registrados ni valoración, y fingirlos sería inventarle un prestigio.
  const stats = [
    guide.years > 0 ? { value: `${guide.years}`, label: 'años de práctica' } : null,
    guide.rating > 0 ? { value: guide.rating.toFixed(1), label: 'valoración', accent: true } : null,
    guide.circleCount > 0 ? { value: `${guide.circleCount}`, label: 'círculos' } : null,
  ].filter(Boolean) as { value: string; label: string; accent?: boolean }[];
  const guideTeachings = teachings.filter((t) => t.authorId === guide.id);
  const guideCircles = circles.filter((c) => c.guideId === guide.id);

  return (
    <Screen padded={false} header={<ScreenHeader title="Perfil de guía" />}>
      <View style={styles.hero}>
        <Avatar initials={guide.initials} accent={guide.accent} size={92} />
        <View style={styles.nameRow}>
          <Text style={styles.name}>{guide.name}</Text>
          {guide.verified ? <Feather name="check-circle" size={16} color={colors.cyan} /> : null}
        </View>
        <Text style={styles.role}>{guide.title}</Text>
        {guide.location ? (
          <View style={styles.locationRow}>
            <Feather name="map-pin" size={12} color={colors.textMuted} />
            <Text style={styles.location}>{guide.location}</Text>
          </View>
        ) : null}
      </View>

      {stats.length > 0 ? (
        <View style={styles.stats}>
          {stats.map((s, i) => (
            <React.Fragment key={s.label}>
              {i > 0 ? <View style={styles.statDivider} /> : null}
              <Stat value={s.value} label={s.label} accent={s.accent} />
            </React.Fragment>
          ))}
        </View>
      ) : null}

      <View style={styles.section}>
        <Text style={styles.bio}>{guide.bio}</Text>
        <View style={styles.chipRow}>
          {guide.approach.map((a) => (
            <Chip key={a} label={a} size="sm" />
          ))}
          {guide.languages.map((l) => (
            <Chip key={l} label={l} size="sm" />
          ))}
        </View>
      </View>

      {guideServices.length > 0 ? (
        <>
          <View style={styles.section}>
            <Button
              label="Ver sus servicios"
              icon="calendar"
              full
              size="lg"
              onPress={() => router.push(`/servicios?guideId=${guide.id}`)}
            />
          </View>

          <View style={styles.section}>
            <SectionHeader
              overline="Servicios"
              title={`${guideServices.length} formas de trabajar`}
              actionLabel="Ver todos"
              onAction={() => router.push(`/servicios?guideId=${guide.id}`)}
            />
          </View>
          <View style={styles.list}>
            {guideServices.slice(0, 2).map((s) => (
              <ServiceCard
                key={s.id}
                service={s}
                onPress={() => router.push(`/reserva/${s.id}`)}
              />
            ))}
          </View>
        </>
      ) : null}

      {guideTeachings.length > 0 ? (
        <>
          <View style={styles.section}>
            <SectionHeader overline="Enseñanzas" title="Lo que ha escrito" />
          </View>
          <View style={styles.list}>
            {guideTeachings.map((t) => (
              <Card key={t.id} onPress={() => router.push(`/lectura/${t.id}`)} padding={16}>
                <Text style={styles.teachingTheme}>{t.theme}</Text>
                <Text style={styles.teachingTitle}>{t.title}</Text>
                <Text style={styles.teachingMeta}>
                  {t.readMinutes} min · {t.publishedOn}
                </Text>
              </Card>
            ))}
          </View>
        </>
      ) : null}

      {guideCircles.length > 0 ? (
        <>
          <View style={styles.section}>
            <SectionHeader overline="Círculos" title="Espacios que sostiene" />
          </View>
          <View style={styles.list}>
            {guideCircles.map((c) => (
              <Card key={c.id} onPress={() => router.push(`/circulos/${c.id}`)} padding={16}>
                <Text style={styles.teachingTitle}>{c.name}</Text>
                <Text style={styles.teachingMeta}>
                  {c.members} miembros · {c.cadence}
                </Text>
              </Card>
            ))}
          </View>
        </>
      ) : null}

      <View style={styles.spacer} />
    </Screen>
  );
}

function Stat({ value, label, accent }: { value: string; label: string; accent?: boolean }) {
  return (
    <View style={styles.stat}>
      <Text style={[styles.statValue, accent && { color: colors.glow }]}>{value}</Text>
      <Text style={styles.statLabel}>{label}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  hero: { alignItems: 'center', gap: 10, paddingHorizontal: screenPadding, marginTop: spacing.md },
  nameRow: { flexDirection: 'row', alignItems: 'center', gap: 8, marginTop: 8 },
  name: {
    ...glowText,
    fontFamily: fonts.display,
    fontSize: 32,
    lineHeight: 38,
    color: colors.text,
    textAlign: 'center',
  },
  role: {
    fontFamily: fonts.displayItalic,
    fontSize: 16,
    color: colors.textSoft,
    textAlign: 'center',
  },
  locationRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  location: { fontFamily: fonts.body, fontSize: 12, color: colors.textMuted },

  stats: {
    flexDirection: 'row',
    alignItems: 'center',
    marginHorizontal: screenPadding,
    marginTop: spacing.xxl,
    paddingVertical: 18,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  stat: { flex: 1, alignItems: 'center', gap: 5 },
  statValue: { fontFamily: fonts.display, fontSize: 26, color: colors.text },
  statLabel: {
    fontFamily: fonts.body,
    fontSize: 10.5,
    letterSpacing: 0.5,
    color: colors.textMuted,
  },
  statDivider: {
    width: StyleSheet.hairlineWidth,
    height: 34,
    backgroundColor: colors.borderSoft,
  },

  section: { paddingHorizontal: screenPadding, marginTop: spacing.xxl },
  bio: {
    fontFamily: fonts.bodyLight,
    fontSize: 15.5,
    lineHeight: 26,
    color: 'rgba(232,243,249,0.84)',
  },
  chipRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm, marginTop: spacing.lg },

  list: { paddingHorizontal: screenPadding, gap: spacing.md, marginTop: spacing.lg },
  teachingTheme: {
    fontFamily: fonts.bodyMedium,
    fontSize: 9.5,
    letterSpacing: 1.6,
    textTransform: 'uppercase',
    color: colors.cyan,
    marginBottom: 6,
  },
  teachingTitle: {
    fontFamily: fonts.displaySemi,
    fontSize: 18,
    lineHeight: 23,
    color: colors.text,
  },
  teachingMeta: {
    fontFamily: fonts.body,
    fontSize: 11.5,
    color: colors.textMuted,
    marginTop: 6,
  },
  spacer: { height: spacing.xxl },
  empty: {
    fontFamily: fonts.body,
    fontSize: 14,
    color: colors.textMuted,
    textAlign: 'center',
    marginTop: spacing.xxxl,
  },
});
