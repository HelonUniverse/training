import {
  Exo2_300Light,
  Exo2_300Light_Italic,
  Exo2_500Medium,
  Exo2_600SemiBold,
  Exo2_700Bold,
} from '@expo-google-fonts/exo-2';
import {
  Inter_300Light,
  Inter_400Regular,
  Inter_500Medium,
  Inter_600SemiBold,
} from '@expo-google-fonts/inter';
import { useFonts } from 'expo-font';
import { Stack, useRouter, useSegments } from 'expo-router';
import * as SplashScreen from 'expo-splash-screen';
import { StatusBar } from 'expo-status-bar';
import React, { useEffect } from 'react';
import { StyleSheet, View } from 'react-native';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { ToastProvider } from '@/components/Toast';
import { AppProvider, useApp } from '@/store/app-store';
import { ContentProvider } from '@/store/content';
import { colors } from '@/theme';

SplashScreen.preventAutoHideAsync().catch(() => {});

export default function RootLayout() {
  const [fontsLoaded, fontError] = useFonts({
    Exo2_300Light,
    Exo2_300Light_Italic,
    Exo2_500Medium,
    Exo2_600SemiBold,
    Exo2_700Bold,
    Inter_300Light,
    Inter_400Regular,
    Inter_500Medium,
    Inter_600SemiBold,
  });

  useEffect(() => {
    if (fontsLoaded || fontError) SplashScreen.hideAsync().catch(() => {});
  }, [fontsLoaded, fontError]);

  if (!fontsLoaded && !fontError) return <View style={styles.boot} />;

  return (
    <GestureHandlerRootView style={styles.flex}>
      <SafeAreaProvider>
        <AppProvider>
          <ContentProvider>
            <ToastProvider>
              <StatusBar style="light" />
              <AuthGate />
              <Stack
                screenOptions={{
                  headerShown: false,
                  animation: 'fade',
                  contentStyle: { backgroundColor: colors.night },
                }}
              >
                <Stack.Screen name="index" options={{ animation: 'none' }} />
                <Stack.Screen name="(auth)" />
                <Stack.Screen name="(tabs)" />
                <Stack.Screen name="lectura/[id]" options={{ animation: 'slide_from_bottom' }} />
                <Stack.Screen
                  name="reserva/[serviceId]"
                  options={{ animation: 'slide_from_bottom' }}
                />
                <Stack.Screen name="admin/index" />
                <Stack.Screen
                  name="admin/ensenanza/[id]"
                  options={{ animation: 'slide_from_bottom' }}
                />
                <Stack.Screen
                  name="admin/guia/[id]"
                  options={{ animation: 'slide_from_bottom' }}
                />
                <Stack.Screen
                  name="admin/encuentro/[id]"
                  options={{ animation: 'slide_from_bottom' }}
                />
                <Stack.Screen
                  name="admin/servicio/[id]"
                  options={{ animation: 'slide_from_bottom' }}
                />
                <Stack.Screen name="admin/personas" />
              </Stack>
            </ToastProvider>
          </ContentProvider>
        </AppProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}

/**
 * La Red es para quien tiene cuenta. Esconder el botón de entrar no basta:
 * sin esto, escribir /hoy a mano o volver con una sesión vieja guardada en el
 * teléfono dejaba pasar a cualquiera. Aquí se comprueba en cada navegación.
 *
 * Pide `user.id`, no solo `user`: así las sesiones de invitada que quedaron
 * guardadas de antes —que no tienen id— también quedan fuera.
 */
function AuthGate() {
  const { state, hydrated, recovering } = useApp();
  const segments = useSegments();
  const router = useRouter();

  const signedIn = !!state.user?.id;
  const group = segments[0] as string | undefined;
  // El splash decide por su cuenta a dónde mandar; no se le interrumpe.
  const onSplash = !group;
  const inAuth = group === '(auth)';
  // Quien llega del correo a poner una contraseña nueva se queda ahí, con
  // sesión o sin ella: expulsarla sería dejarla sin forma de recuperarla.
  const onReset = (segments as string[])[1] === 'nueva-contrasena';

  useEffect(() => {
    if (!hydrated || onSplash || onReset) return;
    if (!signedIn && !inAuth) router.replace('/(auth)/login');
    else if (signedIn && inAuth) router.replace('/(tabs)/hoy');
  }, [hydrated, signedIn, inAuth, onSplash, onReset, router]);

  // Con el enlace abierto, la app lleva a esa pantalla aunque se haya pedido
  // otra ruta: el enlace del correo aterriza en la raíz en algunos clientes.
  useEffect(() => {
    if (!recovering || onReset) return;
    router.replace('/(auth)/nueva-contrasena');
  }, [recovering, onReset, router]);

  return null;
}

const styles = StyleSheet.create({
  flex: { flex: 1 },
  boot: { flex: 1, backgroundColor: colors.night },
});
