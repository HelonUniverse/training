import { Teaching } from './types';

export const teachings: Teaching[] = [
];

export const featuredTeaching = teachings.find((t) => t.featured) ?? teachings[0];

export const findTeaching = (id: string | undefined) => teachings.find((t) => t.id === id);

export const teachingThemes = Array.from(new Set(teachings.map((t) => t.theme)));
