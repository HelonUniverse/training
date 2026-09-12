import { Feather } from '@expo/vector-icons';
import { Image } from 'expo-image';
import { LinearGradient } from 'expo-linear-gradient';
import { useRouter } from 'expo-router';
import React, { useState } from 'react';
import {
  ActivityIndicator,
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

type Mode = 'login' | 'registro';

/** Pantalla 2 — Login / Registro. */
export default function LoginScreen() {
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { signIn, signUp, requestPasswordReset, busy } = useApp();
  const toast = useToast();

  const [mode, setMode] = useState<Mode>('login');
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const submit = async () => {
    if (busy) return;
    setNotice(null);

    const mail = email.trim().toLowerCase();
    if (!mail || !mail.includes('@')) {
      setError('Escribe un correo válido para continuar.');
      return;
    }
    if (mode === 'registro' && !name.trim()) {
      setError('¿Cómo quieres que te llamemos?');
      return;
    }
    if (password.length < 8) {
      setError('La contraseña necesita al menos 8 caracteres.');
      return;
    }
    setError(null);

    const result =
      mode === 'login'
        ? await signIn(mail, password)
        : await signUp(mail, password, name.trim());

    if (!result.ok) {
      setError(result.message ?? 'No pudimos completar la entrada.');
      haptics.warn();
      return;
    }

    // El registro puede requerir confirmar el correo: en ese caso no hay sesión.
    if (result.message) {
      setNotice(result.message);
      haptics.success();
      return;
    }

    haptics.success();
    toast({
      text: mode === 'login' ? 'Bienvenida de vuelta' : 'Tu lugar en la Red está abierto',
      icon: 'sun',
    });
    router.replace('/(tabs)/hoy');
  };

  const forgot = async () => {
    if (busy) return;
    const mail = email.trim().toLowerCase();
    if (!mail || !mail.includes('@')) {
      setError('Escribe tu correo y vuelve a tocar aquí.');
      setNotice(null);
      return;
    }
    setError(null);
    const result = await requestPasswordReset(mail);
    if (!result.ok) {
      setError(result.message ?? 'No se pudo mandar el correo.');
      haptics.warn();
      return;
    }
    haptics.success();
    setNotice(result.message ?? 'Revisa tu correo.');
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
              {mode === 'login'
                ? 'Vuelve al lugar donde tu práctica te espera.'
                : 'Un solo paso para entrar en la Red.'}
            </Text>
          </View>

          <View style={styles.switcher}>
            {(['login', 'registro'] as Mode[]).map((m) => (
              <Pressable
                key={m}
                accessibilityRole="button"
                accessibilityState={{ selected: mode === m }}
                onPress={() => {
                  haptics.select();
                  setMode(m);
                  setError(null);
                  setNotice(null);
                }}
                style={[styles.switchItem, mode === m && styles.switchItemActive]}
              >
                <Text style={[styles.switchLabel, mode === m && styles.switchLabelActive]}>
                  {m === 'login' ? 'Entrar' : 'Crear cuenta'}
                </Text>
              </Pressable>
            ))}
          </View>

          <View style={styles.form}>
            {mode === 'registro' ? (
              <Field
                icon="user"
                label="Nombre"
                value={name}
                onChangeText={setName}
                placeholder="Tu nombre"
                editable={!busy}
              />
            ) : null}
            <Field
              icon="mail"
              label="Correo"
              value={email}
              onChangeText={setEmail}
              placeholder="tucorreo@ejemplo.com"
              keyboardType="email-address"
              editable={!busy}
            />
            <Field
              icon="lock"
              label="Contraseña"
              value={password}
              onChangeText={setPassword}
              placeholder={mode === 'registro' ? 'Mínimo 8 caracteres' : 'Tu contraseña'}
              secure
              editable={!busy}
            />

            {mode === 'login' ? (
              <Pressable
                accessibilityRole="button"
                onPress={forgot}
                disabled={busy}
                style={({ pressed }) => [styles.forgot, pressed && { opacity: 0.6 }]}
              >
                <Text style={styles.forgotText}>Olvidé mi contraseña</Text>
              </Pressable>
            ) : null}

            {error ? <Text style={styles.error}>{error}</Text> : null}
            {notice ? <Text style={styles.notice}>{notice}</Text> : null}

            <Button
              label={mode === 'login' ? 'Entrar a la Red' : 'Crear mi cuenta'}
              onPress={submit}
              size="lg"
              full
              disabled={busy}
              style={{ marginTop: spacing.sm }}
            />

            {busy ? (
              <View style={styles.busy}>
                <ActivityIndicator color={colors.cyan} size="small" />
                <Text style={styles.busyText}>Conectando con la Red…</Text>
              </View>
            ) : (
              <Pressable
                accessibilityRole="button"
                onPress={() => {
                  haptics.select();
                  setMode(mode === 'login' ? 'registro' : 'login');
                  setError(null);
                  setNotice(null);
                }}
                style={({ pressed }) => [styles.guest, pressed && { opacity: 0.6 }]}
              >
                <Text style={styles.guestText}>
                  {mode === 'login' ? '¿Primera vez? Crea tu cuenta' : 'Ya tengo cuenta'}
                </Text>
                <Feather name="arrow-right" size={14} color={colors.cyan} />
              </Pressable>
            )}
          </View>

          <Text style={styles.legal}>
            Tu cuenta guarda tu camino en todos tus dispositivos
          </Text>
        </ScrollView>
      </KeyboardAvoidingView>
    </View>
  );
}

interface FieldProps {
  icon: keyof typeof Feather.glyphMap;
  label: string;
  value: string;
  onChangeText: (v: string) => void;
  placeholder: string;
  secure?: boolean;
  editable?: boolean;
  keyboardType?: 'default' | 'email-address';
}

function Field({
  icon,
  label,
  value,
  onChangeText,
  placeholder,
  secure,
  editable = true,
  keyboardType = 'default',
}: FieldProps) {
  // Escribir una contraseña a ciegas en un teléfono es la primera causa de
  // "no me deja entrar". El ojo la enseña mientras se toca.
  const [visible, setVisible] = useState(false);

  return (
    <View style={styles.field}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <View style={[styles.fieldBox, !editable && styles.fieldBoxOff]}>
        <Feather name={icon} size={16} color={colors.textMuted} />
        <TextInput
          value={value}
          onChangeText={onChangeText}
          placeholder={placeholder}
          placeholderTextColor={colors.textMuted}
          secureTextEntry={secure && !visible}
          keyboardType={keyboardType}
          editable={editable}
          textContentType={secure ? 'password' : keyboardType === 'email-address' ? 'emailAddress' : 'name'}
          autoCapitalize={keyboardType === 'email-address' || secure ? 'none' : 'words'}
          autoCorrect={false}
          style={styles.fieldInput}
          accessibilityLabel={label}
        />
        {secure ? (
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
        ) : null}
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

  switcher: {
    flexDirection: 'row',
    padding: 4,
    borderRadius: radius.pill,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surfaceSunken,
  },
  switchItem: {
    flex: 1,
    paddingVertical: 11,
    alignItems: 'center',
    borderRadius: radius.pill,
  },
  switchItemActive: {
    backgroundColor: colors.cyanGlow,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: 'rgba(111,216,230,0.4)',
  },
  switchLabel: {
    fontFamily: fonts.bodyMedium,
    fontSize: 13,
    letterSpacing: 0.4,
    color: colors.textMuted,
  },
  switchLabelActive: { color: colors.cyan },

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
  fieldBoxOff: { opacity: 0.55 },
  fieldInput: {
    flex: 1,
    fontFamily: fonts.body,
    fontSize: 15,
    color: colors.text,
    padding: 0,
  },
  forgot: { alignSelf: 'flex-start', paddingVertical: 2 },
  forgotText: {
    fontFamily: fonts.body,
    fontSize: 12.5,
    color: colors.textMuted,
    textDecorationLine: 'underline',
  },
  error: {
    fontFamily: fonts.body,
    fontSize: 12.5,
    color: colors.live,
  },
  notice: {
    fontFamily: fonts.body,
    fontSize: 12.5,
    lineHeight: 19,
    color: colors.success,
  },
  busy: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 10,
    paddingVertical: 12,
  },
  busyText: {
    fontFamily: fonts.body,
    fontSize: 13,
    color: colors.textMuted,
  },
  guest: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    paddingVertical: 12,
  },
  guestText: {
    fontFamily: fonts.bodyMedium,
    fontSize: 13,
    letterSpacing: 0.4,
    color: colors.cyan,
  },
  legal: {
    fontFamily: fonts.body,
    fontSize: 11,
    textAlign: 'center',
    color: colors.textMuted,
  },
});
