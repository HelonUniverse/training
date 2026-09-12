import { Feather } from '@expo/vector-icons';
import { useRouter } from 'expo-router';
import React, { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { Button } from '@/components/Button';
import { Card } from '@/components/Card';
import { Screen } from '@/components/Screen';
import { ScreenHeader } from '@/components/ScreenHeader';
import { SectionHeader } from '@/components/SectionHeader';
import { countMembers, fetchBookings, type AdminBooking } from '@/data/admin';
import { useApp } from '@/store/app-store';
import { useContent } from '@/store/content';
import { colors, fonts, glowText, radius, screenPadding, spacing } from '@/theme';

/**
 * Pantalla 15 — Panel. Publicar contenido sin tocar código.
 *
 * Se esconde a quien no es administradora, pero la puerta real está en la base
 * de datos: aunque alguien llegue a esta ruta a mano, no podrá escribir nada.
 */
export default function AdminScreen() {
  const router = useRouter();
  const { state, hasAccounts } = useApp();
  const { teachings, guides, services, circles, liveEvents, source } = useContent();

  const isAdmin = state.user?.role === 'admin';

  const [bookings, setBookings] = useState<AdminBooking[]>([]);
  const [members, setMembers] = useState<number | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!isAdmin || !hasAccounts) return;
    setLoading(true);
    try {
      const [b, m] = await Promise.all([fetchBookings(), countMembers()]);
      setBookings(b);
      setMembers(m);
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudieron leer las reservas');
    } finally {
      setLoading(false);
    }
  }, [isAdmin, hasAccounts]);

  useEffect(() => {
    load();
  }, [load]);

  if (!isAdmin) {
    return (
      <Screen padded={false} header={<ScreenHeader title="Panel" />}>
        <View style={styles.locked}>
          <View style={styles.lockIcon}>
            <Feather name="lock" size={22} color={colors.textMuted} />
          </View>
          <Text style={styles.lockedTitle}>Solo para administradoras</Text>
          <Text style={styles.lockedText}>
            Esta parte de la Red publica contenido para todo el mundo. Si te toca entrar, pide
            que asciendan tu cuenta a administradora.
          </Text>
          <Button label="Volver" variant="outline" size="sm" onPress={() => router.back()} />
        </View>
      </Screen>
    );
  }

  return (
    <Screen padded={false} header={<ScreenHeader title="Panel" />}>
      <View style={styles.head}>
        <Text style={styles.title}>Lo que la Red{'\n'}publica</Text>
        <Text style={styles.lede}>
          Lo que cambies aquí lo ve todo el mundo en cuanto guardes.
        </Text>
      </View>

      {!hasAccounts ? (
        <View style={styles.section}>
          <Card>
            <Text style={styles.warnTitle}>La base de datos no está conectada</Text>
            <Text style={styles.warnText}>
              El panel está listo, pero sin base de datos no hay dónde guardar. Puedes mirar el
              contenido; el botón de guardar te lo va a decir.
            </Text>
          </Card>
        </View>
      ) : null}

      <View style={styles.statsRow}>
        <Stat value={members === null ? '—' : String(members)} label="en la Red" />
        <View style={styles.statDivider} />
        <Stat value={String(teachings.length)} label="enseñanzas" />
        <View style={styles.statDivider} />
        <Stat value={String(bookings.length)} label="reservas" />
      </View>

      <View style={styles.section}>
        <SectionHeader
          overline="Enseñanzas"
          title={`${teachings.length} publicadas`}
          actionLabel="Nueva"
          onAction={() => router.push('/admin/ensenanza/nueva')}
        />
        <View style={{ height: spacing.lg }} />
        <View style={styles.list}>
          {teachings.map((t) => (
            <Row
              key={t.id}
              title={t.title}
              caption={`${t.theme} · ${t.readMinutes} min${t.featured ? ' · portada' : ''}`}
              onPress={() => router.push(`/admin/ensenanza/${t.id}`)}
            />
          ))}
        </View>
      </View>

      <View style={styles.section}>
        <SectionHeader
          overline="Guías"
          title={`${guides.length} en la Red`}
          actionLabel="Nueva"
          onAction={() => router.push('/admin/guia/nueva')}
        />
        <View style={{ height: spacing.lg }} />
        <View style={styles.list}>
          {guides.map((g) => (
            <Row
              key={g.id}
              title={g.name}
              caption={`${g.title}${g.verified ? ' · verificada' : ''}`}
              onPress={() => router.push(`/admin/guia/${g.id}`)}
            />
          ))}
        </View>
      </View>

      <View style={styles.section}>
        <SectionHeader
          overline="En vivo"
          title={liveEvents.length ? `${liveEvents.length} encuentros` : 'Ningún encuentro'}
          actionLabel="Nuevo"
          onAction={() => router.push('/admin/encuentro/nuevo')}
        />
        <View style={{ height: spacing.lg }} />
        {liveEvents.length === 0 ? (
          <Card>
            <Text style={styles.warnText}>
              Los encuentros son lo que más se mueve: una ceremonia es de un día concreto.
              Ábrelos aquí y aparecen en la pestaña En Vivo.
            </Text>
          </Card>
        ) : (
          <View style={styles.list}>
            {liveEvents.map((e) => (
              <Row
                key={e.id}
                title={e.title}
                caption={`${e.startsAt} · ${e.durationMinutes} min${e.status === 'live' ? ' · en vivo' : ''}`}
                onPress={() => router.push(`/admin/encuentro/${e.id}`)}
              />
            ))}
          </View>
        )}
      </View>

      <View style={styles.section}>
        <SectionHeader
          overline="Servicios"
          title={services.length ? `${services.length} a reservar` : 'Nada que reservar'}
          actionLabel="Nuevo"
          onAction={() => router.push('/admin/servicio/nuevo')}
        />
        <View style={{ height: spacing.lg }} />
        {services.length === 0 ? (
          <Card>
            <Text style={styles.warnText}>
              Sin servicios nadie puede reservar con ninguna guía: el botón de reservar no
              existe hasta que haya algo que reservar.
            </Text>
          </Card>
        ) : (
          <View style={styles.list}>
            {services.map((sv) => (
              <Row
                key={sv.id}
                title={sv.name}
                caption={`${guides.find((g) => g.id === sv.guideId)?.name ?? '—'} · ${sv.format} · $${sv.price}`}
                onPress={() => router.push(`/admin/servicio/${sv.id}`)}
              />
            ))}
          </View>
        )}
      </View>

      <View style={styles.section}>
        <SectionHeader
          overline="Personas"
          title={members === null ? 'Quién está en la Red' : `${members} en la Red`}
          actionLabel="Ver todas"
          onAction={() => router.push('/admin/personas')}
        />
        <View style={{ height: spacing.lg }} />
        <Card onPress={() => router.push('/admin/personas')}>
          <Text style={styles.warnText}>
            Dar acceso a alguien: que cree su cuenta en la app y la asciendas desde aquí. Su
            contraseña la elige ella y no la sabe nadie más.
          </Text>
        </Card>
      </View>

      <View style={styles.section}>
        <SectionHeader
          overline="Reservas"
          title={bookings.length ? `${bookings.length} recibidas` : 'Todavía ninguna'}
          actionLabel={loading ? undefined : 'Actualizar'}
          onAction={load}
        />
        <View style={{ height: spacing.lg }} />
        {loading ? (
          <View style={styles.loading}>
            <ActivityIndicator color={colors.cyan} size="small" />
          </View>
        ) : error ? (
          <Card>
            <Text style={styles.warnText}>{error}</Text>
          </Card>
        ) : bookings.length === 0 ? (
          <Card>
            <Text style={styles.warnText}>
              Cuando alguien reserve un servicio, aparece aquí con su nombre y su correo.
            </Text>
          </Card>
        ) : (
          <View style={styles.list}>
            {bookings.map((b) => (
              <Row
                key={b.id}
                title={b.personName}
                caption={`${b.date} · ${b.time}${b.personEmail ? ` · ${b.personEmail}` : ''}`}
              />
            ))}
          </View>
        )}
      </View>

      <View style={styles.section}>
        <Card>
          <Text style={styles.noteTitle}>Lo que todavía no se edita aquí</Text>
          <Text style={styles.warnText}>
            Los círculos ({circles.length}) y las preguntas de Mi Camino se cambian por ahora
            desde Supabase. Contenido {source === 'remote' ? 'en vivo' : 'local'}.
          </Text>
        </Card>
      </View>
    </Screen>
  );
}

function Stat({ value, label }: { value: string; label: string }) {
  return (
    <View style={styles.stat}>
      <Text style={styles.statValue}>{value}</Text>
      <Text style={styles.statLabel}>{label}</Text>
    </View>
  );
}

function Row({
  title,
  caption,
  onPress,
}: {
  title: string;
  caption: string;
  onPress?: () => void;
}) {
  return (
    <Pressable
      accessibilityRole={onPress ? 'button' : undefined}
      disabled={!onPress}
      onPress={onPress}
      style={({ pressed }) => [styles.row, pressed && onPress ? { opacity: 0.7 } : null]}
    >
      <View style={styles.rowText}>
        <Text style={styles.rowTitle} numberOfLines={1}>
          {title}
        </Text>
        <Text style={styles.rowCaption} numberOfLines={1}>
          {caption}
        </Text>
      </View>
      {onPress ? <Feather name="chevron-right" size={17} color={colors.textMuted} /> : null}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  head: { paddingHorizontal: screenPadding, gap: 10, marginBottom: spacing.xl },
  title: { ...glowText, fontFamily: fonts.displayLight, fontSize: 31, lineHeight: 39, color: colors.text },
  lede: { fontFamily: fonts.body, fontSize: 14.5, lineHeight: 22, color: colors.textSoft },

  section: { paddingHorizontal: screenPadding, marginBottom: spacing.xxl },
  list: { gap: 10 },

  statsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginHorizontal: screenPadding,
    marginBottom: spacing.xxl,
    paddingVertical: 18,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  stat: { flex: 1, alignItems: 'center', gap: 3 },
  statDivider: { width: StyleSheet.hairlineWidth, height: 30, backgroundColor: colors.borderSoft },
  statValue: { fontFamily: fonts.displayLight, fontSize: 26, color: colors.text },
  statLabel: { fontFamily: fonts.body, fontSize: 11.5, color: colors.textMuted },

  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    paddingVertical: 14,
    paddingHorizontal: 16,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surface,
  },
  rowText: { flex: 1, gap: 3 },
  rowTitle: { fontFamily: fonts.bodyMedium, fontSize: 14.5, color: colors.text },
  rowCaption: { fontFamily: fonts.body, fontSize: 12, color: colors.textMuted },

  loading: { paddingVertical: 24, alignItems: 'center' },
  warnTitle: { fontFamily: fonts.displaySemi, fontSize: 16, color: colors.text, marginBottom: 8 },
  noteTitle: { fontFamily: fonts.bodyMedium, fontSize: 13.5, color: colors.text, marginBottom: 6 },
  warnText: { fontFamily: fonts.body, fontSize: 13, lineHeight: 20, color: colors.textMuted },

  locked: {
    paddingHorizontal: screenPadding,
    paddingTop: spacing.xxl,
    alignItems: 'center',
    gap: 14,
  },
  lockIcon: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surface,
    marginBottom: 4,
  },
  lockedTitle: { fontFamily: fonts.display, fontSize: 21, color: colors.text },
  lockedText: {
    fontFamily: fonts.body,
    fontSize: 14,
    lineHeight: 22,
    textAlign: 'center',
    color: colors.textMuted,
    marginBottom: 8,
  },
});
