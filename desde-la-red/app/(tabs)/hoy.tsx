import { Feather } from '@expo/vector-icons';
import { useRouter } from 'expo-router';
import React, { useMemo } from 'react';
import { Pressable, ScrollView, Share, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { ActionButton } from '@/components/ActionButton';
import { Avatar } from '@/components/Avatar';
import { Card } from '@/components/Card';
import { CosmicBackground } from '@/components/CosmicBackground';
import { LiveEventCard } from '@/components/LiveEventCard';
import { SectionHeader } from '@/components/SectionHeader';
import { TeachingCard } from '@/components/TeachingCard';
import { TeachingHero } from '@/components/TeachingHero';
import { useToast } from '@/components/Toast';
import { greetingForNow, todayLabel } from '@/lib/format';
import * as haptics from '@/lib/haptics';
import { useContent } from '@/store/content';
import { useApp } from '@/store/app-store';
import { colors, fonts, glowText, radius, screenPadding, spacing, tabBarHeight, type } from '@/theme';

/** Pantalla 3 — Hoy. La pieza central de la app. */
export default function HoyScreen() {
  const { circles, featuredTeaching, findGuide, guides, liveEvents, teachings } = useContent();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const toast = useToast();
  const { state, toggleSaved, isSaved } = useApp();
  const isAdmin = state.user?.role === 'admin';

  const teaching = featuredTeaching;
  const author = teaching ? findGuide(teaching.authorId) : undefined;
  const saved = teaching ? isSaved(teaching.id) : false;
  const nextEvent = useMemo(
    () => liveEvents.find((e) => e.status === 'live') ?? liveEvents[0],
    [liveEvents],
  );
  const nextGuide = nextEvent ? findGuide(nextEvent.guideId) : undefined;
  const moreTeachings = useMemo(
    () => teachings.filter((t) => t.id !== teaching?.id).slice(0, 5),
    [teachings, teaching?.id],
  );

  const firstName = (state.user?.name ?? 'Carla').split(' ')[0];

  const share = async () => {
    if (!teaching) return;
    haptics.tap();
    try {
      await Share.share({
        message: `«${teaching.title}» — una enseñanza de ${author?.name ?? 'la Red'} en Desde la Red.`,
      });
    } catch {
      toast({ text: 'No se pudo compartir ahora', icon: 'alert-circle' });
    }
  };

  return (
    <CosmicBackground horizon>
      <ScrollView
        showsVerticalScrollIndicator={false}
        contentContainerStyle={{
          paddingTop: insets.top + 10,
          paddingBottom: tabBarHeight + insets.bottom + 34,
        }}
      >
        {/* Saludo + avatar */}
        <View style={styles.header}>
          <View style={styles.greetingBox}>
            <Text style={styles.date}>{todayLabel()}</Text>
            <Text style={styles.greeting}>
              {greetingForNow()}, {firstName}
            </Text>
          </View>
          <Pressable
            accessibilityRole="button"
            accessibilityLabel="Abrir mi perfil"
            onPress={() => {
              haptics.tap();
              router.push('/perfil');
            }}
            style={({ pressed }) => pressed && { opacity: 0.7 }}
          >
            <Avatar initials={state.user?.initials ?? 'CM'} size={48} accent="glow" />
          </Pressable>
        </View>

        {/* Enseñanza del día */}
        {teaching ? (
          <View style={styles.block}>
            <TeachingHero
              teaching={teaching}
              guideName={author?.name ?? 'Desde la Red'}
              onPress={() => router.push(`/lectura/${teaching.id}`)}
            />

            <Text style={styles.excerpt}>{teaching.excerpt}</Text>

            <Pressable
              accessibilityRole="button"
              onPress={() => {
                haptics.press();
                router.push(`/lectura/${teaching.id}`);
              }}
              style={({ pressed }) => [styles.readRow, pressed && { opacity: 0.75 }]}
            >
              <Text style={styles.readLabel}>Leer la enseñanza completa</Text>
              <View style={styles.readIcon}>
                <Feather name="arrow-right" size={15} color={colors.glow} />
              </View>
            </Pressable>

            <View style={styles.actions}>
              <ActionButton
                icon="headphones"
                label="Escuchar"
                onPress={() =>
                  toast({ text: `Audio de ${teaching.listenMinutes} min · demo`, icon: 'headphones' })
                }
              />
              <ActionButton
                icon={saved ? 'check' : 'bookmark'}
                label={saved ? 'Guardada' : 'Guardar'}
                active={saved}
                onPress={() => {
                  toggleSaved(teaching.id);
                  toast({
                    text: saved ? 'Quitada de tu biblioteca' : 'Guardada en tu biblioteca',
                    icon: saved ? 'bookmark' : 'check',
                  });
                }}
              />
              <ActionButton icon="share-2" label="Compartir" onPress={share} />
            </View>
          </View>
        ) : (
          <View style={styles.block}>
            <Card glow accent="glow" padding={24}>
              <Text style={styles.practiceOverline}>La Red está en silencio</Text>
              <Text style={styles.silenceTitle}>
                Todavía no hay{'\n'}ninguna enseñanza
              </Text>
              <Text style={styles.practiceBody}>
                {isAdmin
                  ? 'La primera la escribes tú. En cuanto la publiques, esta pantalla se abre con ella.'
                  : 'Vuelve pronto: la primera enseñanza está por llegar.'}
              </Text>
              {isAdmin ? (
                <Pressable
                  accessibilityRole="button"
                  onPress={() => {
                    haptics.press();
                    router.push('/admin/ensenanza/nueva');
                  }}
                  style={({ pressed }) => [styles.readRow, pressed && { opacity: 0.75 }]}
                >
                  <Text style={styles.readLabel}>Escribir la primera</Text>
                  <View style={styles.readIcon}>
                    <Feather name="arrow-right" size={15} color={colors.glow} />
                  </View>
                </Pressable>
              ) : null}
            </Card>
          </View>
        )}

        {/* Próximo evento en vivo */}
        {nextEvent ? (
          <View style={styles.block}>
            <SectionHeader
              overline="En vivo"
              title="Próximo encuentro"
              actionLabel="Ver todo"
              onAction={() => router.push('/(tabs)/en-vivo')}
            />
            <View style={{ height: spacing.lg }} />
            <LiveEventCard
              event={nextEvent}
              guideName={nextGuide?.name ?? ''}
              variant="compact"
              onPress={() => router.push('/(tabs)/en-vivo')}
            />
          </View>
        ) : null}

        {/* Explora hoy */}
        {moreTeachings.length > 0 ? (
          <>
            <View style={styles.block}>
              <SectionHeader
                overline="Explora hoy"
                title="Para seguir caminando"
                actionLabel="Biblioteca"
                onAction={() => router.push('/(tabs)/explorar')}
              />
            </View>

            <ScrollView
              horizontal
              showsHorizontalScrollIndicator={false}
              contentContainerStyle={styles.carousel}
            >
              {moreTeachings.map((t) => (
                <TeachingCard
                  key={t.id}
                  teaching={t}
                  saved={isSaved(t.id)}
                  onPress={() => router.push(`/lectura/${t.id}`)}
                />
              ))}
            </ScrollView>
          </>
        ) : null}

        {/* Accesos rápidos */}
        <View style={styles.block}>
          <View style={styles.quickGrid}>
            <QuickTile
              icon="users"
              title="Círculos"
              caption={circles.length > 0 ? `${circles.length} activos` : 'Ninguno todavía'}
              onPress={() => router.push('/circulos')}
            />
            <QuickTile
              icon="compass"
              title="Guías"
              caption={guides.length > 0 ? `${guides.length} en la Red` : 'Ninguna todavía'}
              onPress={() => router.push('/guias')}
            />
          </View>
        </View>

        {/* Práctica del día */}
        <View style={styles.block}>
          <Card glow accent="glow" padding={22}>
            <Text style={styles.practiceOverline}>Práctica de hoy</Text>
            <Text style={styles.practiceTitle}>Cinco minutos antes del teléfono</Text>
            <Text style={styles.practiceBody}>
              Al despertar, siéntate cinco minutos con la pregunta que más te pesa. No la
              respondas. Solo sostenla.
            </Text>
            <View style={styles.streakRow}>
              <Feather name="sunrise" size={14} color={colors.glow} />
              <Text style={styles.streakText}>
                Llevas {state.practiceDays} días seguidos
              </Text>
            </View>
          </Card>
        </View>
      </ScrollView>
    </CosmicBackground>
  );
}

function QuickTile({
  icon,
  title,
  caption,
  onPress,
}: {
  icon: keyof typeof Feather.glyphMap;
  title: string;
  caption: string;
  onPress: () => void;
}) {
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={title}
      onPress={() => {
        haptics.tap();
        onPress();
      }}
      style={({ pressed }) => [styles.quickTile, pressed && { opacity: 0.85 }]}
    >
      <View style={styles.quickIcon}>
        <Feather name={icon} size={17} color={colors.cyan} />
      </View>
      <Text style={styles.quickTitle}>{title}</Text>
      <Text style={styles.quickCaption}>{caption}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: screenPadding,
    paddingBottom: spacing.xl,
  },
  greetingBox: { flex: 1, gap: 7 },
  date: {
    fontFamily: fonts.bodyMedium,
    fontSize: 10,
    letterSpacing: 2,
    textTransform: 'uppercase',
    color: colors.cyan,
  },
  greeting: {
    ...glowText,
    fontFamily: fonts.display,
    fontSize: 30,
    lineHeight: 36,
    letterSpacing: 0.2,
    color: colors.text,
  },

  block: { paddingHorizontal: screenPadding, marginBottom: spacing.xxxl },

  excerpt: {
    ...type.serifBody,
    marginTop: spacing.xl,
  },
  readRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: spacing.xl,
    paddingVertical: spacing.md,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
  },
  readLabel: {
    fontFamily: fonts.bodyMedium,
    fontSize: 13.5,
    letterSpacing: 0.5,
    color: colors.glow,
  },
  readIcon: {
    width: 34,
    height: 34,
    borderRadius: 17,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderGlow,
    backgroundColor: colors.glowSoft,
  },
  actions: { flexDirection: 'row', gap: spacing.sm, marginTop: spacing.lg },

  carousel: {
    paddingHorizontal: screenPadding,
    gap: spacing.md,
    paddingBottom: spacing.xxxl,
  },

  quickGrid: { flexDirection: 'row', gap: spacing.md },
  quickTile: {
    flex: 1,
    padding: 18,
    gap: 6,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  quickIcon: {
    width: 38,
    height: 38,
    borderRadius: 19,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: colors.cyanGlow,
    marginBottom: 6,
  },
  quickTitle: {
    fontFamily: fonts.displaySemi,
    fontSize: 18,
    color: colors.text,
  },
  quickCaption: { fontFamily: fonts.body, fontSize: 11.5, color: colors.textMuted },

  practiceOverline: {
    fontFamily: fonts.bodyMedium,
    fontSize: 10,
    letterSpacing: 2,
    textTransform: 'uppercase',
    color: colors.glow,
  },
  silenceTitle: {
    fontFamily: fonts.displayLight,
    fontSize: 27,
    lineHeight: 34,
    color: colors.text,
    marginTop: 8,
    marginBottom: 10,
  },
  practiceTitle: {
    fontFamily: fonts.display,
    fontSize: 24,
    lineHeight: 30,
    color: colors.text,
    marginTop: 10,
  },
  practiceBody: {
    fontFamily: fonts.body,
    fontSize: 13.5,
    lineHeight: 21,
    color: colors.textSoft,
    marginTop: 10,
  },
  streakRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginTop: 18,
    paddingTop: 14,
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.borderSoft,
  },
  streakText: { fontFamily: fonts.bodyMedium, fontSize: 12, color: colors.glow },
});
