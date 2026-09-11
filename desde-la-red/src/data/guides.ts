import { Guide, Service } from './types';

export const guides: Guide[] = [
  // Las guías reales de la Red van primero. years, circleCount y rating en 0
  // significan "todavía no lo sabemos": la app no enseña esas cifras cuando
  // valen cero, en vez de inventarles antigüedad o estrellas.
  {
    id: 'g-virginia',
    name: 'Virginia Godoy',
    title: 'Terapeuta holística y guía de autoconocimiento',
    location: '',
    initials: 'VG',
    accent: 'electric',
    years: 0,
    circleCount: 0,
    rating: 0,
    bio: 'Su trabajo se sostiene sobre cuatro pilares: energía, consciencia, bienestar y naturaleza. Reúne la sanación energética —Reiki Usui y activación Kundalini—, el autoconocimiento a través de los Registros Akáshicos y Mujer Alquimia, el bienestar emocional con terapia floral y Flores de Bach, y la práctica de Hatha Yoga junto a la sabiduría de las plantas.',
    approach: [
      'Reiki Usui',
      'Kundalini',
      'Registros Akáshicos',
      'Mujer Alquimia',
      'Flores de Bach',
      'Terapia floral',
      'Hatha Yoga',
      'Herbolaria',
    ],
    languages: ['Español'],
    serviceIds: [],
    verified: false,
  },
  {
    id: 'g-adhara',
    name: 'Adhara Esteves',
    title: 'Fundadora de Arbor Domus · Herbolaria',
    location: '',
    initials: 'AE',
    accent: 'glow',
    years: 0,
    circleCount: 0,
    rating: 0,
    bio: 'Adhara Esteves nos conecta con la sabiduría de las plantas y nos recuerda que volver a la naturaleza también es volver a nosotros mismos. Desde Arbor Domus une la herbolaria y el conocimiento botánico con el cuidado natural de la piel y la cosmética artesanal: productos hechos a mano, elaborados con intención, que convierten el autocuidado en ritual.',
    approach: [
      'Herbolaria',
      'Skincare natural',
      'Cosmética botánica',
      'Ritual de autocuidado',
      'Creación artesanal',
    ],
    languages: ['Español'],
    serviceIds: [],
    verified: false,
  },
];

export const services: Service[] = [
];

export const findGuide = (id: string | undefined) => guides.find((g) => g.id === id);
export const findService = (id: string | undefined) => services.find((s) => s.id === id);
export const servicesOfGuide = (guideId: string) => services.filter((s) => s.guideId === guideId);
