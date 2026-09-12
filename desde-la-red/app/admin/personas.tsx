import { Feather } from '@expo/vector-icons';
import React, { useCallback, useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from 'react-native';

import { Avatar } from '@/components/Avatar';
import { Card } from '@/components/Card';
import { Screen } from '@/components/Screen';
import { ScreenHeader } from '@/components/ScreenHeader';
import { SearchField } from '@/components/SearchField';
import { useToast } from '@/components/Toast';
import { fetchMembers, setMemberRole, type Member } from '@/data/admin';
import { matches } from '@/lib/format';
import * as haptics from '@/lib/haptics';
import { useApp } from '@/store/app-store';
import { colors, fonts, glowText, radius, screenPadding, spacing } from '@/theme';

const initialsOf = (m: Member) =>
  m.name
    .trim()
    .split(/\s+/)
    .slice(0, 2)
    .map((w) => w[0]?.toUpperCase() ?? '')
    .join('') || '·';

/** Pantalla 21 — Quién está en la Red, y quién puede publicar. */
export default function PersonasScreen() {
  const { state } = useApp();
  const toast = useToast();

  const [members, setMembers] = useState<Member[]>([]);
  const [query, setQuery] = useState('');
  const [loading, setLoading] = useState(true);
  const [working, setWorking] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const isAdmin = state.user?.role === 'admin';

  const load = useCallback(async () => {
    if (!isAdmin) return;
    setLoading(true);
    try {
      setMembers(await fetchMembers());
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo leer quién está en la Red');
    } finally {
      setLoading(false);
    }
  }, [isAdmin]);

  useEffect(() => {
    load();
  }, [load]);

  const toggle = async (m: Member) => {
    const next = m.role === 'admin' ? 'member' : 'admin';
    setWorking(m.id);
    const result = await setMemberRole(m.id, next);
    setWorking(null);

    if (!result.ok) {
      setError(result.message ?? 'No se pudo cambiar el rol.');
      haptics.warn();
      return;
    }
    setError(null);
    haptics.success();
    setMembers((list) => list.map((x) => (x.id === m.id ? { ...x, role: next } : x)));
    toast({
      text: next === 'admin' ? `${m.name} ya puede publicar` : `${m.name} vuelve a ser miembro`,
      icon: next === 'admin' ? 'shield' : 'user',
    });
  };

  if (!isAdmin) {
    return (
      <Screen header={<ScreenHeader title="Personas" />}>
        <Text style={styles.denied}>Esta pantalla es para administradoras.</Text>
      </Screen>
    );
  }

  const results = members.filter((m) => matches(query, m.name, m.email ?? ''));
  const admins = members.filter((m) => m.role === 'admin').length;

  return (
    <Screen padded={false} header={<ScreenHeader title="Personas" />}>
      <View style={styles.head}>
        <Text style={styles.title}>Quién está{'\n'}en la Red</Text>
        <Text style={styles.lede}>
          {members.length === 1 ? '1 persona' : `${members.length} personas`} ·{' '}
          {admins === 1 ? '1 administradora' : `${admins} administradoras`}
        </Text>
      </View>

      <View style={styles.search}>
        <SearchField
          value={query}
          onChangeText={setQuery}
          placeholder="Buscar por nombre o correo..."
        />
      </View>

      {error ? (
        <View style={styles.section}>
          <Card>
            <Text style={styles.error}>{error}</Text>
          </Card>
        </View>
      ) : null}

      {loading ? (
        <View style={styles.loading}>
          <ActivityIndicator color={colors.cyan} size="small" />
        </View>
      ) : results.length === 0 ? (
        <View style={styles.section}>
          <Card>
            <Text style={styles.note}>
              {members.length === 0
                ? 'Todavía no hay nadie más. Cuando alguien cree su cuenta, aparece aquí.'
                : 'Nadie coincide con esa búsqueda.'}
            </Text>
          </Card>
        </View>
      ) : (
        <View style={styles.list}>
          {results.map((m) => {
            const yo = m.id === state.user?.id;
            const admin = m.role === 'admin';
            return (
              <View key={m.id} style={styles.row}>
                <Avatar initials={initialsOf(m)} size={44} accent={admin ? 'glow' : 'cyan'} />
                <View style={styles.rowText}>
                  <View style={styles.nameRow}>
                    <Text style={styles.name} numberOfLines={1}>
                      {m.name}
                    </Text>
                    {yo ? <Text style={styles.you}>tú</Text> : null}
                  </View>
                  <Text style={styles.email} numberOfLines={1}>
                    {m.email ?? 'sin correo'}
                  </Text>
                  <View style={styles.roleRow}>
                    <Feather
                      name={admin ? 'shield' : 'user'}
                      size={10.5}
                      color={admin ? colors.glow : colors.textMuted}
                    />
                    <Text style={[styles.role, admin && styles.roleAdmin]}>
                      {admin ? 'Puede publicar' : 'Miembro'}
                    </Text>
                  </View>
                </View>

                {yo ? (
                  <Text style={styles.locked}>—</Text>
                ) : (
                  <Pressable
                    accessibilityRole="button"
                    accessibilityLabel={
                      admin ? `Retirar permisos a ${m.name}` : `Dar permisos a ${m.name}`
                    }
                    disabled={working === m.id}
                    onPress={() => toggle(m)}
                    style={({ pressed }) => [
                      styles.action,
                      admin && styles.actionOn,
                      pressed && { opacity: 0.7 },
                    ]}
                  >
                    {working === m.id ? (
                      <ActivityIndicator size="small" color={colors.cyan} />
                    ) : (
                      <Text style={[styles.actionText, admin && styles.actionTextOn]}>
                        {admin ? 'Retirar' : 'Ascender'}
                      </Text>
                    )}
                  </Pressable>
                )}
              </View>
            );
          })}
        </View>
      )}

      <View style={styles.section}>
        <Card>
          <Text style={styles.noteTitle}>Cómo se le da acceso a alguien</Text>
          <Text style={styles.note}>
            Que cree su cuenta en la app con su propio correo y su propia contraseña — nadie
            más la sabe. Cuando aparezca en esta lista, la asciendes aquí y ya puede publicar.
          </Text>
          <View style={{ height: 10 }} />
          <Text style={styles.note}>
            Tu propio rol no se puede cambiar desde aquí, y la Red nunca se queda sin
            administradoras: eso lo impide la base de datos, no esta pantalla.
          </Text>
        </Card>
      </View>
    </Screen>
  );
}

const styles = StyleSheet.create({
  head: { paddingHorizontal: screenPadding, gap: 8, marginBottom: spacing.xl },
  title: {
    ...glowText,
    fontFamily: fonts.displayLight,
    fontSize: 31,
    lineHeight: 39,
    color: colors.text,
  },
  lede: { fontFamily: fonts.body, fontSize: 14, color: colors.textSoft },
  search: { paddingHorizontal: screenPadding, marginBottom: spacing.xl },
  section: { paddingHorizontal: screenPadding, marginBottom: spacing.xxl },
  list: { paddingHorizontal: screenPadding, gap: 10, marginBottom: spacing.xxl },

  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 13,
    padding: 14,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surface,
  },
  rowText: { flex: 1, gap: 3 },
  nameRow: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  name: { fontFamily: fonts.bodyMedium, fontSize: 14.5, color: colors.text },
  you: {
    fontFamily: fonts.body,
    fontSize: 10,
    letterSpacing: 1,
    textTransform: 'uppercase',
    color: colors.textMuted,
  },
  email: { fontFamily: fonts.body, fontSize: 12, color: colors.textMuted },
  roleRow: { flexDirection: 'row', alignItems: 'center', gap: 5, marginTop: 2 },
  role: { fontFamily: fonts.body, fontSize: 11.5, color: colors.textMuted },
  roleAdmin: { color: colors.glow },

  action: {
    paddingHorizontal: 14,
    paddingVertical: 9,
    minWidth: 82,
    alignItems: 'center',
    borderRadius: radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderGlow,
    backgroundColor: colors.cyanGlow,
  },
  actionOn: { borderColor: colors.borderSoft, backgroundColor: colors.surfaceSunken },
  actionText: { fontFamily: fonts.bodyMedium, fontSize: 12.5, color: colors.cyan },
  actionTextOn: { color: colors.textMuted },
  locked: { width: 82, textAlign: 'center', color: colors.textMuted, fontFamily: fonts.body },

  loading: { paddingVertical: 28, alignItems: 'center' },
  noteTitle: { fontFamily: fonts.bodyMedium, fontSize: 13.5, color: colors.text, marginBottom: 6 },
  note: { fontFamily: fonts.body, fontSize: 13, lineHeight: 20, color: colors.textMuted },
  error: { fontFamily: fonts.body, fontSize: 13, lineHeight: 20, color: colors.live },
  denied: { fontFamily: fonts.body, fontSize: 14, color: colors.textMuted },
});
