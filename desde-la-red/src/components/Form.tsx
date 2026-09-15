import { Feather } from '@expo/vector-icons';
import React from 'react';
import {
  Pressable,
  StyleProp,
  StyleSheet,
  Text,
  TextInput,
  View,
  ViewStyle,
} from 'react-native';

import * as haptics from '@/lib/haptics';
import { colors, fonts, radius, spacing } from '@/theme';

/**
 * Los controles del panel de administración. Comparten la misma piel oscura
 * del resto de la app: caja translúcida, borde cyan fino, etiqueta en
 * versalitas.
 */

/** Métrica de la caja de texto, para estimar cuántas líneas ocupa. */
const LINE_HEIGHT = 22;
const PADDING_X = 16;
const PADDING_Y = 14;
/** Ancho medio de un carácter de Inter a 15px. */
const CHAR_WIDTH = 7.6;

interface FieldProps {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  placeholder?: string;
  helper?: string;
  multiline?: boolean;
  minHeight?: number;
  keyboardType?: 'default' | 'numeric';
  autoCapitalize?: 'none' | 'sentences' | 'words';
  editable?: boolean;
  style?: StyleProp<ViewStyle>;
}

export function Field({
  label,
  value,
  onChangeText,
  placeholder,
  helper,
  multiline,
  minHeight,
  keyboardType = 'default',
  autoCapitalize = 'sentences',
  editable = true,
  style,
}: FieldProps) {
  // Un campo largo que recorta el texto esconde justo lo que se escribe, así
  // que crece con el contenido. La altura se calcula a partir del texto y del
  // ancho medido — nunca a partir de la altura, que se realimentaría sola.
  const floor = minHeight ?? 110;
  const [width, setWidth] = React.useState(0);

  const height = React.useMemo(() => {
    if (!multiline) return undefined;
    if (!width) return floor;
    const perLine = Math.max(18, Math.floor((width - PADDING_X * 2) / CHAR_WIDTH));
    const lines = value
      .split('\n')
      .reduce((n, line) => n + Math.max(1, Math.ceil(line.length / perLine)), 0);
    return Math.max(floor, lines * LINE_HEIGHT + PADDING_Y * 2);
  }, [multiline, value, width, floor]);

  return (
    <View style={[styles.field, style]}>
      {label ? <Text style={styles.label}>{label}</Text> : null}
      <TextInput
        value={value}
        onChangeText={onChangeText}
        placeholder={placeholder}
        placeholderTextColor={colors.textMuted}
        multiline={multiline}
        keyboardType={keyboardType}
        autoCapitalize={autoCapitalize}
        editable={editable}
        onLayout={multiline ? (e) => setWidth(e.nativeEvent.layout.width) : undefined}
        style={[
          styles.input,
          multiline && { height, paddingTop: PADDING_Y, textAlignVertical: 'top' },
          !editable && { opacity: 0.55 },
        ]}
        accessibilityLabel={label || placeholder}
      />
      {helper ? <Text style={styles.helper}>{helper}</Text> : null}
    </View>
  );
}

interface OptionsProps<T extends string> {
  label: string;
  value: T;
  options: readonly T[];
  onChange: (v: T) => void;
  helper?: string;
  labelOf?: (v: T) => string;
}

/** Elección única, en píldoras. Para temas, formatos, acentos. */
export function Options<T extends string>({
  label,
  value,
  options,
  onChange,
  helper,
  labelOf,
}: OptionsProps<T>) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <View style={styles.pills}>
        {options.map((o) => {
          const on = o === value;
          return (
            <Pressable
              key={o}
              accessibilityRole="button"
              accessibilityState={{ selected: on }}
              onPress={() => {
                haptics.select();
                onChange(o);
              }}
              style={({ pressed }) => [
                styles.pill,
                on && styles.pillOn,
                pressed && { opacity: 0.7 },
              ]}
            >
              <Text style={[styles.pillText, on && styles.pillTextOn]}>
                {labelOf ? labelOf(o) : o}
              </Text>
            </Pressable>
          );
        })}
      </View>
      {helper ? <Text style={styles.helper}>{helper}</Text> : null}
    </View>
  );
}

interface SwitchRowProps {
  label: string;
  helper?: string;
  value: boolean;
  onChange: (v: boolean) => void;
}

/** Interruptor con su explicación, en una fila tocable entera. */
export function SwitchRow({ label, helper, value, onChange }: SwitchRowProps) {
  return (
    <Pressable
      accessibilityRole="switch"
      accessibilityState={{ checked: value }}
      onPress={() => {
        haptics.select();
        onChange(!value);
      }}
      style={({ pressed }) => [styles.switchRow, pressed && { opacity: 0.75 }]}
    >
      <View style={styles.switchText}>
        <Text style={styles.switchLabel}>{label}</Text>
        {helper ? <Text style={styles.helper}>{helper}</Text> : null}
      </View>
      <View style={[styles.check, value && styles.checkOn]}>
        {value ? <Feather name="check" size={13} color={colors.night} /> : null}
      </View>
    </Pressable>
  );
}

interface TagsProps {
  label: string;
  values: string[];
  onChange: (v: string[]) => void;
  placeholder?: string;
  helper?: string;
}

/** Lista de etiquetas: se escribe una y se añade; se toca para quitarla. */
export function Tags({ label, values, onChange, placeholder, helper }: TagsProps) {
  const [draft, setDraft] = React.useState('');

  const add = () => {
    const v = draft.trim();
    if (!v || values.includes(v)) {
      setDraft('');
      return;
    }
    onChange([...values, v]);
    setDraft('');
    haptics.tap();
  };

  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      {values.length ? (
        <View style={styles.pills}>
          {values.map((v) => (
            <Pressable
              key={v}
              accessibilityRole="button"
              accessibilityLabel={`Quitar ${v}`}
              onPress={() => {
                haptics.tap();
                onChange(values.filter((x) => x !== v));
              }}
              style={({ pressed }) => [styles.tag, pressed && { opacity: 0.6 }]}
            >
              <Text style={styles.tagText}>{v}</Text>
              <Feather name="x" size={11} color={colors.textMuted} />
            </Pressable>
          ))}
        </View>
      ) : null}
      <View style={styles.tagAdd}>
        <TextInput
          value={draft}
          onChangeText={setDraft}
          placeholder={placeholder ?? 'Añadir…'}
          placeholderTextColor={colors.textMuted}
          onSubmitEditing={add}
          returnKeyType="done"
          autoCapitalize="none"
          style={[styles.input, styles.tagInput]}
          accessibilityLabel={label}
        />
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Añadir"
          onPress={add}
          style={({ pressed }) => [styles.tagButton, pressed && { opacity: 0.7 }]}
        >
          <Feather name="plus" size={16} color={colors.cyan} />
        </Pressable>
      </View>
      {helper ? <Text style={styles.helper}>{helper}</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  field: { gap: 9 },
  label: {
    fontFamily: fonts.bodyMedium,
    fontSize: 10.5,
    letterSpacing: 1.8,
    textTransform: 'uppercase',
    color: colors.textMuted,
  },
  input: {
    minHeight: 52,
    paddingHorizontal: 16,
    paddingVertical: 14,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    fontFamily: fonts.body,
    fontSize: 15,
    lineHeight: 22,
    color: colors.text,
  },
  helper: { fontFamily: fonts.body, fontSize: 12, lineHeight: 17, color: colors.textMuted },

  pills: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  pill: {
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surfaceSunken,
  },
  pillOn: { borderColor: colors.borderGlow, backgroundColor: colors.cyanGlow },
  pillText: { fontFamily: fonts.body, fontSize: 13, color: colors.textMuted },
  pillTextOn: { fontFamily: fonts.bodyMedium, color: colors.cyan },

  switchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.lg,
    paddingVertical: 14,
    paddingHorizontal: 16,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  switchText: { flex: 1, gap: 3 },
  switchLabel: { fontFamily: fonts.bodyMedium, fontSize: 14.5, color: colors.text },
  check: {
    width: 24,
    height: 24,
    borderRadius: 7,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
  },
  checkOn: { backgroundColor: colors.cyan, borderColor: colors.cyan },

  tag: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    paddingHorizontal: 12,
    paddingVertical: 7,
    borderRadius: radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surfaceSunken,
  },
  tagText: { fontFamily: fonts.body, fontSize: 12.5, color: colors.textSoft },
  tagAdd: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  tagInput: { flex: 1, minHeight: 46, paddingVertical: 11 },
  tagButton: {
    width: 46,
    height: 46,
    borderRadius: radius.md,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
});
