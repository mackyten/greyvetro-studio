export interface Voice {
  id: string;
  name: string;
  description: string;
  isCustom: boolean;
  previewUrl?: string | null;
  labels: Record<string, string>;
}

export function voiceTagline(v: Voice): string {
  const parts = [
    v.labels['gender'],
    v.labels['accent'],
    v.labels['age'],
    v.labels['use case'] ?? v.labels['use_case'] ?? v.labels['useCase'],
  ].filter((p): p is string => !!p && p.trim().length > 0);
  return parts.length > 0 ? parts.join(' · ') : v.description;
}

export interface Usage {
  characterCount: number;
  characterLimit: number;
  tier: string;
  canCloneVoices: boolean;
  nextReset?: string | null;
}

export interface TtsModel {
  id: string;
  label: string;
  short: string;
  hint: string;
}

export const MODELS: TtsModel[] = [
  {
    id: 'eleven_multilingual_v2',
    label: 'Multilingual v2',
    short: 'v2',
    hint: 'Balanced, natural narration.',
  },
  {
    id: 'eleven_v3',
    label: 'Eleven v3',
    short: 'v3',
    hint: 'Most expressive. Reads audio tags in the script: [excited] [whispers] [laughs] [shouts].',
  },
  {
    id: 'eleven_turbo_v2_5',
    label: 'Turbo v2.5',
    short: 'Turbo',
    hint: 'Faster, ~half the credits.',
  },
  {
    id: 'eleven_flash_v2_5',
    label: 'Flash v2.5',
    short: 'Flash',
    hint: 'Fastest and cheapest.',
  },
];

export const DEFAULT_MODEL_ID = 'eleven_multilingual_v2';

export interface VoiceSettings {
  stability: number;
  similarityBoost: number;
  style: number;
  useSpeakerBoost: boolean;
  modelId?: string; // absent = DEFAULT_MODEL_ID (older stored items predate this field)
}

export const defaultSettings: VoiceSettings = {
  stability: 0.5,
  similarityBoost: 0.75,
  style: 0,
  useSpeakerBoost: true,
  modelId: DEFAULT_MODEL_ID,
};

export function modelShort(modelId?: string): string {
  return MODELS.find((m) => m.id === (modelId ?? DEFAULT_MODEL_ID))?.short ?? modelId ?? 'v2';
}

export function settingsSummary(s: Partial<VoiceSettings>): string {
  const stability = s.stability ?? defaultSettings.stability;
  const similarityBoost = s.similarityBoost ?? defaultSettings.similarityBoost;
  const style = s.style ?? defaultSettings.style;
  const useSpeakerBoost = s.useSpeakerBoost ?? defaultSettings.useSpeakerBoost;
  return `Stab ${stability.toFixed(2)} · Sim ${similarityBoost.toFixed(2)} · Style ${style.toFixed(2)} · Boost ${useSpeakerBoost ? 'on' : 'off'} · ${modelShort(s.modelId)}`;
}

/** True when voice + model + the four setting values match (name-independent). */
export function sameSettings(
  a: { voiceId: string } & VoiceSettings,
  voiceId: string,
  s: VoiceSettings,
): boolean {
  const near = (x: number, y: number) => Math.abs(x - y) < 0.0005;
  return (
    a.voiceId === voiceId &&
    (a.modelId ?? DEFAULT_MODEL_ID) === (s.modelId ?? DEFAULT_MODEL_ID) &&
    a.useSpeakerBoost === s.useSpeakerBoost &&
    near(a.stability, s.stability) &&
    near(a.similarityBoost, s.similarityBoost) &&
    near(a.style, s.style)
  );
}

export interface TranscriptWord {
  text: string;
  /** Seconds from the start of the audio. */
  start: number;
  end: number;
  /** 'word' | 'spacing' | 'audio_event' (ElevenLabs Scribe categories). */
  type: string;
}

export interface Transcript {
  text: string;
  languageCode: string;
  words: TranscriptWord[];
}

/** A storyboard scene proposed from a transcript (Greyvetro Studio). */
export interface Scene {
  start: number; // seconds
  end: number;
  narration: string;
  imagePrompt: string;
}

/** A scene persisted on a project's storyboard (image blob lives in IndexedDB). */
export interface StoredScene extends Scene {
  id: string;
  projectId: string;
  clipId: string; // the gallery clip providing the voiceover
  order: number;
  hasImage: boolean;
}

export interface GalleryItem extends VoiceSettings {
  id: string;
  text: string;
  voiceId: string;
  voiceName: string;
  createdAt: string; // ISO
  projectId?: string; // absent = "Unsorted"
  title?: string;
  transcript?: Transcript; // word-timestamped STT result, set on demand
}

export interface Project {
  id: string;
  name: string;
  createdAt: string; // ISO
}

/** Default clip title: the first few words of the script. */
export function autoTitle(text: string): string {
  const words = text.trim().split(/\s+/).slice(0, 5).join(' ');
  return words.length > 32 ? `${words.slice(0, 32).trimEnd()}…` : words;
}

/** Filesystem-safe name for downloads/zips. */
export function slugify(s: string): string {
  return (
    s
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 48) || 'clip'
  );
}

/** A saved bundle of voice + settings — a "sound", not content (no text). */
export interface Preset extends VoiceSettings {
  id: string;
  name: string;
  voiceId: string;
  voiceName: string;
  createdAt: string; // ISO
}

/** Payload loaded into the composer from the gallery or a preset. */
export interface Draft {
  nonce: number;
  voiceId: string;
  voiceName: string;
  settings: VoiceSettings;
  text?: string;
}
