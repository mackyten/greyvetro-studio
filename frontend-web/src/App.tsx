import { useCallback, useEffect, useState } from 'react';
import { Link, Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { getUsage } from './core/api';
import { Icon } from './core/Icon';
import { defaultSettings, type Draft, type GalleryItem, type Preset, type Usage } from './core/types';
import { useTheme } from './core/useTheme';
import { GalleryScreen } from './features/gallery/GalleryScreen';
import { PresetsScreen } from './features/presets/PresetsScreen';
import { StoryboardScreen } from './features/storyboard/StoryboardScreen';
import { TimelineScreen } from './features/timeline/TimelineScreen';
import { Composer } from './features/tts/Composer';
import { UsageCard } from './features/usage/UsageCard';

type Tab = 'studio' | 'gallery' | 'storyboard' | 'timeline' | 'presets';

const TABS: { id: Tab; icon: string; label: string }[] = [
  { id: 'studio', icon: 'mic', label: 'Studio' },
  { id: 'gallery', icon: 'headphones', label: 'Gallery' },
  { id: 'storyboard', icon: 'movie', label: 'Storyboard' },
  { id: 'timeline', icon: 'theaters', label: 'Timeline' },
  { id: 'presets', icon: 'tune', label: 'Presets' },
];

const TAB_PATH: Record<Tab, string> = {
  studio: '/',
  gallery: '/gallery',
  storyboard: '/storyboard',
  timeline: '/timeline',
  presets: '/presets',
};

function tabFromPath(pathname: string): Tab {
  return TABS.find((t) => TAB_PATH[t.id] === pathname)?.id ?? 'studio';
}

const PAGE_META: Record<Tab, { title: string; subtitle: string }> = {
  studio: { title: 'Studio', subtitle: 'Turn your script into speech with ElevenLabs voices.' },
  gallery: { title: 'Gallery', subtitle: 'Takes you chose to keep, saved locally in this browser.' },
  storyboard: {
    title: 'Storyboard',
    subtitle: 'Turn a project’s voiceover into timed scenes with images, then preview the cut.',
  },
  timeline: {
    title: 'Timeline',
    subtitle: 'The storyboard laid out as editable tracks — the source of truth for the render.',
  },
  presets: { title: 'Presets', subtitle: 'Saved voice + settings bundles, ready to re-apply.' },
};

export default function App() {
  const { theme, toggle } = useTheme();
  const location = useLocation();
  const navigate = useNavigate();
  const tab = tabFromPath(location.pathname);
  const [usage, setUsage] = useState<Usage | null>(null);
  const [draft, setDraft] = useState<Draft | null>(null);

  const refreshUsage = useCallback(() => {
    getUsage().then(setUsage).catch(() => setUsage(null));
  }, []);

  useEffect(refreshUsage, [refreshUsage]);

  const loadIntoComposer = (
    source: GalleryItem | Preset,
    text?: string,
  ) => {
    setDraft({
      nonce: Date.now(),
      voiceId: source.voiceId,
      voiceName: source.voiceName,
      settings: {
        stability: source.stability ?? defaultSettings.stability,
        similarityBoost: source.similarityBoost ?? defaultSettings.similarityBoost,
        style: source.style ?? defaultSettings.style,
        useSpeakerBoost: source.useSpeakerBoost ?? defaultSettings.useSpeakerBoost,
        modelId: source.modelId,
      },
      text,
    });
    navigate(TAB_PATH.studio);
  };

  return (
    <div className="shell">
      <aside className="sidebar">
        <div className="sidebar-logo">
          <div className="mark">G</div>
          <div className="name">Greyvetro</div>
        </div>
        {TABS.map((t) => (
          <Link
            key={t.id}
            to={TAB_PATH[t.id]}
            className={`nav-item${tab === t.id ? ' active' : ''}`}
          >
            <Icon name={t.icon} /> {t.label}
          </Link>
        ))}
        <div className="sidebar-footer">
          <UsageCard usage={usage} />
          <button className="theme-toggle" onClick={toggle}>
            {theme === 'dark' ? (
              <>
                <Icon name="light_mode" /> Light mode
              </>
            ) : (
              <>
                <Icon name="dark_mode" /> Dark mode
              </>
            )}
          </button>
        </div>
      </aside>
      <main className="main">
        <div className="page-title">
          <h1>{PAGE_META[tab].title}</h1>
          <p>{PAGE_META[tab].subtitle}</p>
        </div>
        {/* Composer stays mounted (outside <Routes>) so its state survives tab switches. */}
        <div style={{ display: tab === 'studio' ? undefined : 'none' }}>
          <Composer draft={draft} onGenerated={refreshUsage} />
        </div>
        <Routes>
          <Route path={TAB_PATH.studio} element={null} />
          <Route
            path={TAB_PATH.gallery}
            element={
              <GalleryScreen
                onEditRegenerate={(item) => loadIntoComposer(item, item.text)}
                onUseSettings={(item) => loadIntoComposer(item)}
              />
            }
          />
          <Route path={TAB_PATH.storyboard} element={<StoryboardScreen />} />
          <Route path={TAB_PATH.timeline} element={<TimelineScreen />} />
          <Route path={TAB_PATH.presets} element={<PresetsScreen onUse={(p) => loadIntoComposer(p)} />} />
          <Route path="*" element={<Navigate to={TAB_PATH.studio} replace />} />
        </Routes>
      </main>
    </div>
  );
}
