import { Feather } from '@expo/vector-icons';
import { Image } from 'expo-image';
import { LinearGradient } from 'expo-linear-gradient';
import { useRouter } from 'expo-router';
import React, { useState } from 'react';
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { BrandLogo } from '@/components/BrandLogo';
import { Button } from '@/components/Button';
import { useToast } from '@/components/Toast';
import { imageSource } from '@/data/images';
import * as haptics from '@/lib/haptics';
import { useApp } from '@/store/app-store';
import { colors, fonts, radius, screenPadding, spacing } from '@/theme';

/**
 * Pantalla 18 — Contraseña nueva.
 *
 * Aquí se llega desde el enlace del correo. Esa sesión de recuperación sirve
 * para esto y nada más: hasta guardar la contraseña, la app no deja entrar.
 */
export default function NuevaContrasenaScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const toast = useToast();
  const { updatePassword, recovering, busy } = useApp();

  const [password, setPassword] = useState('');
  const [repeat, setRepeat] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const submit = async () => {
    if (busy) return;
    if (password.length < 8) {
      setError('La contraseña necesita al menos 8 caracteres.');
      return;
    }
    if (password !== repeat) {
      setError('Las dos contraseñas no son iguales.');
      return;
    }
    setError(null);

    const result = await updatePassword(password);
    if (!result.ok) {
      setError(result.message ?? 'No se pudo cambiar la contraseña.');
      haptics.warn();
      return;
    }
    haptics.success();
    if (result.message) {
      setNotice(result.message);
      return;
    }
    toast({ text: 'Contraseña nueva guardada', icon: 'check' });
    router.replace('/(tabs)/hoy');
  };

  return (
    <View style={styles.root}>
      <Image source={imageSource('bg-auth')} style={StyleSheet.absoluteFill} contentFit="cover" />
      <LinearGradient
        colors={['rgba(3,8,20,0.45)', 'rgba(3,8,20,0.9)', 'rgba(3,8,20,0.6)']}
        locations={[0, 0.55, 1]}
        style={StyleSheet.absoluteFill}
      />

      <KeyboardAvoidingView
        style={styles.flex}
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      >
        <ScrollView
          contentContainerStyle={[
            styles.scroll,
            { paddingTop: insets.top + 70, paddingBottom: insets.bottom + 36 },
          ]}
          showsVerticalScrollIndicator={false}
          keyboardShouldPersistTaps="handled"
        >
          <View style={styles.brand}>
            <BrandLogo size={64} align="left" />
            <Text style={styles.tagline}>
              {recovering
                ? 'Elige una contraseña nueva y vuelves a entrar.'
                : 'Abre el enlace que te llegó al correo para cambiarla.'}
            </Text>
          </View>

          {recovering ? (
            <View style={styles.form}>
              <Field
                label="Contraseña nueva"
                value={password}
                onChangeText={setPassword}
                placeholder="Mínimo 8 caracteres"
                editable={!busy}
              />
              <Field
                label="Repítela"
                value={repeat}
                onChangeText={setRepeat}
                placeholder="La misma otra vez"
                editable={!busy}
              />

              {error ? <Text style={styles.error}>{error}</Text> : null}
              {notice ? <Text style={styles.notice}>{notice}</Text> : null}

              <Button
                label="Guardar y entrar"
                onPress={submit}
                size="lg"
                full
                loading={busy}
                disabled={busy}
                style={{ marginTop: spacing.sm }}
              />
            </View>
          ) : (
            <View style={styles.form}>
              <Text style={styles.expired}>
                Este enlace ya no sirve, o se abrió en un navegador distinto del que lo pidió.
                Vuelve a pedirlo desde la pantalla de entrada.
              </Text>
            </View>
          )}

          <Pressable
            accessibilityRole="button"
            onPress={() => router.replace('/(auth)/login')}
            style={({ pressed }) => [styles.back, pressed && { opacity: 0.6 }]}
          >
            <Feather name="arrow-left" size={14} color={colors.cyan} />
            <Text style={styles.backText}>Volver a entrar</Text>
          </Pressable>
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

function Field({
  label,
  value,
  onChangeText,
  placeholder,
  editable = true,
}: {
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  placeholder: string;
  editable?: boolean;
}) {
  // Aquí hay que escribirla dos veces iguales: poder verla importa todavía más.
  const [visible, setVisible] = useState(false);

  return (
    <View style={styles.field}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <View style={[styles.fieldBox, !editable && { opacity: 0.55 }]}>
        <Feather name="lock" size={16} color={colors.textMuted} />
        <TextInput
          value={value}
          onChangeText={onChangeText}
          placeholder={placeholder}
          placeholderTextColor={colors.textMuted}
          secureTextEntry={!visible}
          editable={editable}
          textContentType="newPassword"
          autoCapitalize="none"
          autoCorrect={false}
          style={styles.fieldInput}
          accessibilityLabel={label}
        />
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={visible ? 'Ocultar contraseña' : 'Mostrar contraseña'}
          accessibilityState={{ selected: visible }}
          onPress={() => setVisible((v) => !v)}
          hitSlop={10}
          style={({ pressed }) => pressed && { opacity: 0.6 }}
        >
          <Feather
            name={visible ? 'eye-off' : 'eye'}
            size={16}
            color={visible ? colors.cyan : colors.textMuted}
          />
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.night },
  flex: { flex: 1 },
  scroll: { paddingHorizontal: screenPadding, gap: spacing.xxl },

  brand: { gap: 12 },
  tagline: {
    fontFamily: fonts.body,
    fontSize: 14.5,
    lineHeight: 22,
    color: colors.textSoft,
    marginTop: 4,
  },

  form: { gap: spacing.lg },
  field: { gap: 8 },
  fieldLabel: {
    fontFamily: fonts.bodyMedium,
    fontSize: 10.5,
    letterSpacing: 1.8,
    textTransform: 'uppercase',
    color: colors.textMuted,
  },
  fieldBox: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    height: 54,
    paddingHorizontal: 18,
    borderRadius: radius.md,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
  },
  fieldInput: {
    flex: 1,
    fontFamily: fonts.body,
    fontSize: 15,
    color: colors.text,
    padding: 0,
  },
  error: { fontFamily: fonts.body, fontSize: 12.5, color: colors.live },
  notice: { fontFamily: fonts.body, fontSize: 12.5, lineHeight: 19, color: colors.success },
  expired: {
    fontFamily: fonts.body,
    fontSize: 14,
    lineHeight: 22,
    color: colors.textMuted,
  },

  back: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    paddingVertical: 12,
  },
  backText: {
    fontFamily: fonts.bodyMedium,
    fontSize: 13,
    letterSpacing: 0.4,
    color: colors.cyan,
  },
});
