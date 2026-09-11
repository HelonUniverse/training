import { Feather } from '@expo/vector-icons';
import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { Guide } from '@/data/types';
import * as haptics from '@/lib/haptics';
import { colors, fonts, radius } from '@/theme';

import { Avatar } from './Avatar';
import { Chip } from './Chip';

interface Props {
  guide: Guide;
  onPress: () => void;
  variant?: 'row' | 'tile';
}

export function GuideCard({ guide, onPress, variant = 'row' }: Props) {
  const handlePress = () => {
    haptics.tap();
    onPress();
  };

  if (variant === 'tile') {
    return (
      <Pressable
        accessibilityRole="button"
        accessibilityLabel={`Ver perfil de ${guide.name}`}
        onPress={handlePress}
        style={({ pressed }) => [styles.tile, pressed && styles.pressed]}
      >
        <Avatar initials={guide.initials} accent={guide.accent} size={58} />
        <Text style={styles.tileName} numberOfLines={1}>
          {guide.name}
        </Text>
        <Text style={styles.tileTitle} numberOfLines={2}>
          {guide.title}
        </Text>
        {guide.rating > 0 ? (
          <View style={styles.ratingRow}>
            <Feather name="star" size={11} color={colors.glow} />
            <Text style={styles.rating}>{guide.rating.toFixed(1)}</Text>
          </View>
        ) : null}
      </Pressable>
    );
  }

  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={`Ver perfil de ${guide.name}`}
      onPress={handlePress}
      style={({ pressed }) => [styles.row, pressed && styles.pressed]}
    >
      <Avatar initials={guide.initials} accent={guide.accent} size={56} />
      <View style={styles.rowBody}>
        <View style={styles.nameRow}>
          <Text style={styles.name} numberOfLines={1}>
            {guide.name}
          </Text>
          {guide.verified ? <Feather name="check-circle" size={13} color={colors.cyan} /> : null}
        </View>
        <Text style={styles.title} numberOfLines={1}>
          {guide.title}
        </Text>
        {guide.location || guide.rating > 0 ? (
          <View style={styles.metaRow}>
            {guide.location ? (
              <>
                <Feather name="map-pin" size={10.5} color={colors.textMuted} />
                <Text style={styles.meta}>{guide.location}</Text>
              </>
            ) : null}
            {guide.location && guide.rating > 0 ? <View style={styles.dot} /> : null}
            {guide.rating > 0 ? (
              <>
                <Feather name="star" size={10.5} color={colors.glow} />
                <Text style={styles.meta}>{guide.rating.toFixed(1)}</Text>
              </>
            ) : null}
          </View>
        ) : null}
        <View style={styles.chips}>
          {guide.approach.slice(0, 2).map((a) => (
            <Chip key={a} label={a} size="sm" />
          ))}
        </View>
      </View>
      <Feather name="chevron-right" size={18} color={colors.textMuted} />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  pressed: { opacity: 0.85, transform: [{ scale: 0.99 }] },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
    padding: 16,
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  rowBody: { flex: 1, gap: 4 },
  nameRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  name: {
    fontFamily: fonts.displaySemi,
    fontSize: 19,
    lineHeight: 24,
    color: colors.text,
  },
  title: {
    fontFamily: fonts.body,
    fontSize: 12.5,
    color: colors.textSoft,
  },
  metaRow: { flexDirection: 'row', alignItems: 'center', gap: 5, marginTop: 2 },
  meta: { fontFamily: fonts.body, fontSize: 11, color: colors.textMuted },
  dot: { width: 3, height: 3, borderRadius: 2, backgroundColor: colors.textMuted, marginHorizontal: 3 },
  chips: { flexDirection: 'row', gap: 6, marginTop: 8, flexWrap: 'wrap' },

  tile: {
    width: 152,
    padding: 16,
    gap: 8,
    alignItems: 'center',
    borderRadius: radius.lg,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  tileName: {
    fontFamily: fonts.displaySemi,
    fontSize: 16,
    lineHeight: 20,
    color: colors.text,
    marginTop: 4,
    textAlign: 'center',
  },
  tileTitle: {
    fontFamily: fonts.body,
    fontSize: 11,
    lineHeight: 15,
    color: colors.textMuted,
    textAlign: 'center',
  },
  ratingRow: { flexDirection: 'row', alignItems: 'center', gap: 4, marginTop: 2 },
  rating: { fontFamily: fonts.bodyMedium, fontSize: 11.5, color: colors.glow },
});
