import AsyncStorage from '@react-native-async-storage/async-storage';
import type { Session } from '@supabase/supabase-js';
import { Platform } from 'react-native';
import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from 'react';

import { initialsFrom } from '@/data/remote';
import type { Booking } from '@/data/types';
import { authErrorMessage, isBackendConfigured, supabase } from '@/lib/supabase';

const STORAGE_KEY = 'desde-la-red:state:v1';

export interface DemoUser {
  id: string | null;
  name: string;
  email: string;
  initials: string;
  role: 'member' | 'admin';
  joinedOn: string;
}

export interface AppState {
  user: DemoUser | null;
  savedTeachings: string[];
  readTeachings: string[];
  joinedCircles: string[];
  resonatedPosts: string[];
  pathAnswers: Record<string, string[]>;
  pathSavedAt: string | null;
  bookings: Booking[];
  practiceDays: number;
}

const initialState: AppState = {
  user: null,
  savedTeachings: [],
  readTeachings: [],
  joinedCircles: [],
  resonatedPosts: [],
  pathAnswers: {},
  pathSavedAt: null,
  bookings: [],
  practiceDays: 7,
};

export interface AuthResult {
  ok: boolean;
  /** Mensaje listo para mostrar; también cuando hace falta confirmar el correo. */
  message?: string;
}

interface AppContextValue {
  state: AppState;
  hydrated: boolean;
  /** true cuando hay Supabase configurado: hay cuentas de verdad. */
  hasAccounts: boolean;
  busy: boolean;
  signIn: (email: string, password: string) => Promise<AuthResult>;
  signUp: (email: string, password: string, name: string) => Promise<AuthResult>;
  signOut: () => Promise<void>;
  /** Manda el correo con el enlace para poner una contraseña nueva. */
  requestPasswordReset: (email: string) => Promise<AuthResult>;
  /** Guarda la contraseña nueva. Solo funciona con el enlace del correo abierto. */
  updatePassword: (password: string) => Promise<AuthResult>;
  /** true mientras se está usando un enlace de recuperación. */
  recovering: boolean;
  toggleSaved: (teachingId: string) => void;
  isSaved: (teachingId: string) => boolean;
  markAsRead: (teachingId: string) => void;
  toggleCircle: (circleId: string) => void;
  isInCircle: (circleId: string) => boolean;
  toggleResonance: (postId: string) => void;
  hasResonated: (postId: string) => boolean;
  setPathAnswer: (questionId: string, optionId: string, multiple: boolean) => void;
  savePath: () => void;
  resetPath: () => void;
  addBooking: (booking: Omit<Booking, 'id' | 'createdAt'>) => Booking;
  cancelBooking: (bookingId: string) => void;
  resetDemo: () => void;
}

const AppContext = createContext<AppContextValue | null>(null);

const toggleIn = (list: string[], value: string) =>
  list.includes(value) ? list.filter((item) => item !== value) : [...list, value];

export function AppProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<AppState>(initialState);
  const [hydrated, setHydrated] = useState(false);
  const [busy, setBusy] = useState(false);
  const [recovering, setRecovering] = useState(false);
  const hydratedRef = useRef(false);
  const userIdRef = useRef<string | null>(null);

  userIdRef.current = state.user?.id ?? null;

  // --- Persistencia local ---------------------------------------------------
  // Siempre se guarda en el dispositivo. Con cuenta, además se sincroniza.
  useEffect(() => {
    let active = true;
    (async () => {
      try {
        const raw = await AsyncStorage.getItem(STORAGE_KEY);
        if (active && raw) setState({ ...initialState, ...(JSON.parse(raw) as Partial<AppState>) });
      } catch {
        // Sin almacenamiento seguimos con el estado inicial.
      } finally {
        if (active) {
          hydratedRef.current = true;
          setHydrated(true);
        }
      }
    })();
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!hydratedRef.current) return;
    AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(state)).catch(() => {});
  }, [state]);

  // --- Sesión de Supabase ---------------------------------------------------
  const loadProfile = useCallback(async (session: Session) => {
    if (!supabase) return;
    const uid = session.user.id;

    const { data: profile } = await supabase
      .from('profiles')
      .select('name, email, role')
      .eq('id', uid)
      .maybeSingle();

    const name = profile?.name || session.user.email?.split('@')[0] || 'Caminante';

    const [saved, read, circles, resonances, answers, bookings] = await Promise.all([
      supabase.from('saved_teachings').select('teaching_id').eq('user_id', uid),
      supabase.from('read_teachings').select('teaching_id').eq('user_id', uid),
      supabase.from('circle_members').select('circle_id').eq('user_id', uid),
      supabase.from('post_resonances').select('post_id').eq('user_id', uid),
      supabase.from('path_answers').select('question_id, option_ids, updated_at').eq('user_id', uid),
      supabase
        .from('bookings')
        .select('id, service_id, guide_id, date_label, time_label, note, created_at')
        .eq('user_id', uid)
        .order('created_at', { ascending: false }),
    ]);

    const pathAnswers: Record<string, string[]> = {};
    let pathSavedAt: string | null = null;
    for (const row of answers.data ?? []) {
      pathAnswers[row.question_id] = row.option_ids ?? [];
      if (!pathSavedAt || row.updated_at > pathSavedAt) pathSavedAt = row.updated_at;
    }

    setState((prev) => ({
      ...prev,
      user: {
        id: uid,
        name,
        email: profile?.email || session.user.email || '',
        initials: initialsFrom(name),
        role: profile?.role === 'admin' ? 'admin' : 'member',
        joinedOn: session.user.created_at ?? new Date().toISOString(),
      },
      savedTeachings: (saved.data ?? []).map((r) => r.teaching_id),
      readTeachings: (read.data ?? []).map((r) => r.teaching_id),
      joinedCircles: (circles.data ?? []).map((r) => r.circle_id),
      resonatedPosts: (resonances.data ?? []).map((r) => r.post_id),
      pathAnswers,
      pathSavedAt,
      bookings: (bookings.data ?? []).map((r) => ({
        id: r.id,
        serviceId: r.service_id,
        guideId: r.guide_id ?? '',
        date: r.date_label,
        time: r.time_label,
        note: r.note ?? undefined,
        createdAt: r.created_at,
      })),
    }));
  }, []);

  useEffect(() => {
    if (!supabase) return;
    supabase.auth.getSession().then(({ data }) => {
      if (data.session) loadProfile(data.session).catch(() => {});
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      // El enlace del correo abre una sesión de recuperación. Sirve para
      // guardar una contraseña nueva y para nada más: no se carga el perfil,
      // así el guardia de rutas no la deja pasar a la app.
      if (event === 'PASSWORD_RECOVERY') {
        setRecovering(true);
        return;
      }
      if (session && (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED')) {
        loadProfile(session).catch(() => {});
      }
      if (event === 'SIGNED_OUT') setState({ ...initialState });
    });
    return () => sub.subscription.unsubscribe();
  }, [loadProfile]);

  // --- Sincronización de una fila propia ------------------------------------
  /** Escribe en la tabla si hay cuenta; si no, se queda solo en el dispositivo. */
  const sync = useCallback(
    (
      table: string,
      column: string,
      value: string,
      shouldExist: boolean,
    ) => {
      const uid = userIdRef.current;
      if (!supabase || !uid) return;
      const op = shouldExist
        ? supabase.from(table).upsert({ user_id: uid, [column]: value })
        : supabase.from(table).delete().eq('user_id', uid).eq(column, value);
      Promise.resolve(op).catch(() => {});
    },
    [],
  );

  // --- Autenticación --------------------------------------------------------
  const signUp = useCallback(
    async (email: string, password: string, name: string): Promise<AuthResult> => {
      if (!supabase) return { ok: false, message: 'El backend no está configurado.' };
      setBusy(true);
      try {
        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: { data: { name: name.trim() } },
        });
        if (error) return { ok: false, message: authErrorMessage(error) };
        if (!data.session) {
          return { ok: true, message: 'Te mandamos un correo para confirmar tu cuenta.' };
        }
        await loadProfile(data.session);
        return { ok: true };
      } finally {
        setBusy(false);
      }
    },
    [loadProfile],
  );

  const signIn = useCallback(
    async (email: string, password: string): Promise<AuthResult> => {
      if (!supabase) return { ok: false, message: 'El backend no está configurado.' };
      setBusy(true);
      try {
        const { data, error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        });
        if (error) return { ok: false, message: authErrorMessage(error) };
        if (data.session) await loadProfile(data.session);
        return { ok: true };
      } finally {
        setBusy(false);
      }
    },
    [loadProfile],
  );

  /**
   * El correo de recuperación devuelve a la app con una sesión especial. Hasta
   * que no se guarde la contraseña nueva, esa sesión no debe servir para
   * entrar: de ahí `recovering`, que el guardia de rutas respeta.
   */
  const requestPasswordReset = useCallback(async (email: string): Promise<AuthResult> => {
    if (!supabase) return { ok: false, message: 'El backend no está configurado.' };
    setBusy(true);
    try {
      const redirectTo =
        Platform.OS === 'web' && typeof window !== 'undefined'
          ? `${window.location.origin}/nueva-contrasena`
          : undefined;
      const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo });
      if (error) return { ok: false, message: authErrorMessage(error) };
      return { ok: true, message: 'Te mandamos un enlace para poner una contraseña nueva.' };
    } finally {
      setBusy(false);
    }
  }, []);

  const updatePassword = useCallback(async (password: string): Promise<AuthResult> => {
    if (!supabase) return { ok: false, message: 'El backend no está configurado.' };
    setBusy(true);
    try {
      const { data, error } = await supabase.auth.updateUser({ password });
      if (error) return { ok: false, message: authErrorMessage(error) };
      setRecovering(false);
      const { data: sesion } = await supabase.auth.getSession();
      if (sesion.session) await loadProfile(sesion.session);
      else if (data.user) return { ok: true, message: 'Contraseña cambiada. Ya puedes entrar.' };
      return { ok: true };
    } finally {
      setBusy(false);
    }
  }, [loadProfile]);

  const signOut = useCallback(async () => {
    if (supabase) await supabase.auth.signOut().catch(() => {});
    setRecovering(false);
    setState({ ...initialState });
  }, []);

  // --- Acciones -------------------------------------------------------------
  const toggleSaved = useCallback(
    (teachingId: string) => {
      setState((prev) => {
        const next = toggleIn(prev.savedTeachings, teachingId);
        sync('saved_teachings', 'teaching_id', teachingId, next.includes(teachingId));
        return { ...prev, savedTeachings: next };
      });
    },
    [sync],
  );

  const markAsRead = useCallback(
    (teachingId: string) => {
      setState((prev) => {
        if (prev.readTeachings.includes(teachingId)) return prev;
        sync('read_teachings', 'teaching_id', teachingId, true);
        return { ...prev, readTeachings: [...prev.readTeachings, teachingId] };
      });
    },
    [sync],
  );

  const toggleCircle = useCallback(
    (circleId: string) => {
      setState((prev) => {
        const next = toggleIn(prev.joinedCircles, circleId);
        sync('circle_members', 'circle_id', circleId, next.includes(circleId));
        return { ...prev, joinedCircles: next };
      });
    },
    [sync],
  );

  const toggleResonance = useCallback(
    (postId: string) => {
      setState((prev) => {
        const next = toggleIn(prev.resonatedPosts, postId);
        sync('post_resonances', 'post_id', postId, next.includes(postId));
        return { ...prev, resonatedPosts: next };
      });
    },
    [sync],
  );

  const setPathAnswer = useCallback(
    (questionId: string, optionId: string, multiple: boolean) => {
      setState((prev) => {
        const current = prev.pathAnswers[questionId] ?? [];
        const next = multiple
          ? current.includes(optionId)
            ? current.filter((id) => id !== optionId)
            : [...current, optionId]
          : current.includes(optionId)
            ? []
            : [optionId];

        const uid = userIdRef.current;
        if (supabase && uid) {
          supabase
            .from('path_answers')
            .upsert({
              user_id: uid,
              question_id: questionId,
              option_ids: next,
              updated_at: new Date().toISOString(),
            })
            .then(undefined, () => {});
        }

        return { ...prev, pathAnswers: { ...prev.pathAnswers, [questionId]: next } };
      });
    },
    [],
  );

  const savePath = useCallback(() => {
    setState((prev) => ({ ...prev, pathSavedAt: new Date().toISOString() }));
  }, []);

  const resetPath = useCallback(() => {
    const uid = userIdRef.current;
    if (supabase && uid) {
      supabase.from('path_answers').delete().eq('user_id', uid).then(undefined, () => {});
    }
    setState((prev) => ({ ...prev, pathAnswers: {}, pathSavedAt: null }));
  }, []);

  const addBooking = useCallback((booking: Omit<Booking, 'id' | 'createdAt'>) => {
    const created: Booking = {
      ...booking,
      id: `b-${Date.now().toString(36)}`,
      createdAt: new Date().toISOString(),
    };

    const uid = userIdRef.current;
    if (supabase && uid) {
      supabase
        .from('bookings')
        .insert({
          user_id: uid,
          service_id: booking.serviceId,
          guide_id: booking.guideId,
          date_label: booking.date,
          time_label: booking.time,
          note: booking.note ?? null,
        })
        .select('id')
        .single()
        .then(({ data }) => {
          // La base manda un id real: se cambia el provisional por el suyo.
          if (data?.id) {
            setState((prev) => ({
              ...prev,
              bookings: prev.bookings.map((b) => (b.id === created.id ? { ...b, id: data.id } : b)),
            }));
          }
        }, () => {});
    }

    setState((prev) => ({ ...prev, bookings: [created, ...prev.bookings] }));
    return created;
  }, []);

  const cancelBooking = useCallback((bookingId: string) => {
    const uid = userIdRef.current;
    if (supabase && uid) {
      supabase.from('bookings').delete().eq('id', bookingId).then(undefined, () => {});
    }
    setState((prev) => ({ ...prev, bookings: prev.bookings.filter((b) => b.id !== bookingId) }));
  }, []);

  const resetDemo = useCallback(() => {
    setState({ ...initialState });
  }, []);

  const value = useMemo<AppContextValue>(
    () => ({
      state,
      hydrated,
      hasAccounts: isBackendConfigured,
      busy,
      signIn,
      signUp,
      signOut,
      requestPasswordReset,
      updatePassword,
      recovering,
      toggleSaved,
      isSaved: (id: string) => state.savedTeachings.includes(id),
      markAsRead,
      toggleCircle,
      isInCircle: (id: string) => state.joinedCircles.includes(id),
      toggleResonance,
      hasResonated: (id: string) => state.resonatedPosts.includes(id),
      setPathAnswer,
      savePath,
      resetPath,
      addBooking,
      cancelBooking,
      resetDemo,
    }),
    [
      state, hydrated, busy, recovering, signIn, signUp, signOut,
      requestPasswordReset, updatePassword, toggleSaved,
      markAsRead, toggleCircle, toggleResonance, setPathAnswer, savePath, resetPath,
      addBooking, cancelBooking, resetDemo,
    ],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useApp() {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error('useApp debe usarse dentro de <AppProvider>');
  return ctx;
}
