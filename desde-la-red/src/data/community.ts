import { Circle, LiveEvent, NetworkPost, PathQuestion } from './types';

export const liveEvents: LiveEvent[] = [
];

export const circles: Circle[] = [
];

export const networkPosts: NetworkPost[] = [
];

export const pathQuestions: PathQuestion[] = [
  {
    id: 'q-intencion',
    prompt: '¿Qué buscas en este momento?',
    helper: 'Elige hasta dos. Podrás cambiarlo cuando quieras.',
    multiple: true,
    options: [
      { id: 'calma', label: 'Calma', description: 'Bajar el ruido interno y dormir mejor' },
      { id: 'claridad', label: 'Claridad', description: 'Entender una decisión que me pesa' },
      { id: 'duelo', label: 'Acompañamiento', description: 'Atravesar una pérdida o un cierre' },
      { id: 'proposito', label: 'Propósito', description: 'Reconocer hacia dónde quiero ir' },
    ],
  },
  {
    id: 'q-ritmo',
    prompt: '¿Cuánto tiempo tienes al día?',
    helper: 'Sé honesta. Es mejor poco y sostenido.',
    multiple: false,
    options: [
      { id: '5', label: '5 minutos', description: 'Una práctica mínima diaria' },
      { id: '15', label: '15 minutos', description: 'Lectura y práctica corta' },
      { id: '30', label: '30 minutos o más', description: 'Práctica profunda y escritura' },
    ],
  },
  {
    id: 'q-momento',
    prompt: '¿En qué momento del día?',
    helper: 'La Red te recordará a esa hora.',
    multiple: false,
    options: [
      { id: 'amanecer', label: 'Al amanecer', description: 'Antes de que empiece el ruido' },
      { id: 'mediodia', label: 'Mediodía', description: 'Una pausa en medio del día' },
      { id: 'noche', label: 'Al anochecer', description: 'Cerrar el día en silencio' },
    ],
  },
  {
    id: 'q-forma',
    prompt: '¿Cómo prefieres recibir la enseñanza?',
    helper: 'Elige todas las que resuenen.',
    multiple: true,
    options: [
      { id: 'lectura', label: 'Lectura', description: 'Textos para leer con calma' },
      { id: 'audio', label: 'Audio', description: 'Escuchar mientras camino' },
      { id: 'circulo', label: 'Círculo', description: 'Acompañada por otras personas' },
      { id: 'guia', label: 'Guía', description: 'Sesiones uno a uno' },
    ],
  },
];

export const findCircle = (id: string | undefined) => circles.find((c) => c.id === id);
export const findEvent = (id: string | undefined) => liveEvents.find((e) => e.id === id);
