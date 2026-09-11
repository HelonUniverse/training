import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import { circles as localCircles, liveEvents as localEvents, networkPosts as localPosts, pathQuestions as localQuestions } from '@/data/community';
import { guides as localGuides, services as localServices } from '@/data/guides';
import { fetchContent, type RemoteContent } from '@/data/remote';
import { teachings as localTeachings } from '@/data/teachings';
import type { Circle, Guide, Service, Teaching } from '@/data/types';
import { isBackendConfigured } from '@/lib/supabase';

/** El contenido empaquetado con la app: lo que se ve mientras carga la Red. */
const LOCAL: RemoteContent = {
  guides: localGuides,
  services: localServices,
  teachings: localTeachings,
  circles: localCircles,
  liveEvents: localEvents,
  posts: localPosts,
  pathQuestions: localQuestions,
};

interface ContentValue extends RemoteContent {
  /** `local` = contenido empaquetado; `remote` = el de la base de datos. */
  source: 'local' | 'remote';
  loading: boolean;
  error: string | null;
  /** La enseñanza que abre la app. `null` mientras no haya ninguna. */
  featuredTeaching: Teaching | null;
  teachingThemes: string[];
  findGuide: (id?: string) => Guide | undefined;
  findService: (id?: string) => Service | undefined;
  findTeaching: (id?: string) => Teaching | undefined;
  findCircle: (id?: string) => Circle | undefined;
  servicesOfGuide: (guideId: string) => Service[];
  refresh: () => Promise<void>;
}

const ContentContext = createContext<ContentValue | null>(null);

export function ContentProvider({ children }: { children: React.ReactNode }) {
  const [content, setContent] = useState<RemoteContent>(LOCAL);
  const [source, setSource] = useState<'local' | 'remote'>('local');
  const [loading, setLoading] = useState(isBackendConfigured);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    if (!isBackendConfigured) return;
    setLoading(true);
    try {
      const remote = await fetchContent();
      // Una Red recién abierta está vacía de verdad, y eso es un estado
      // legítimo: si volviéramos al contenido local, reaparecería el de
      // muestra que ya se retiró. En cuanto la base responde, manda ella.
      if (remote) {
        setContent(remote);
        setSource('remote');
      }
      setError(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'No se pudo cargar el contenido');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  const value = useMemo<ContentValue>(() => {
    const { guides, services, teachings, circles } = content;
    return {
      ...content,
      source,
      loading,
      error,
      featuredTeaching: teachings.find((t) => t.featured) ?? teachings[0] ?? null,
      teachingThemes: Array.from(new Set(teachings.map((t) => t.theme))),
      findGuide: (id) => guides.find((g) => g.id === id),
      findService: (id) => services.find((s) => s.id === id),
      findTeaching: (id) => teachings.find((t) => t.id === id),
      findCircle: (id) => circles.find((c) => c.id === id),
      servicesOfGuide: (guideId) => services.filter((s) => s.guideId === guideId),
      refresh: load,
    };
  }, [content, source, loading, error, load]);

  return <ContentContext.Provider value={value}>{children}</ContentContext.Provider>;
}

export function useContent() {
  const ctx = useContext(ContentContext);
  if (!ctx) throw new Error('useContent debe usarse dentro de <ContentProvider>');
  return ctx;
}
