import JSZip from 'jszip';
import { useEffect, useState } from 'react';
import { transcribeAudio } from '../../core/api';
import { Icon } from '../../core/Icon';
import { useToast } from '../../core/toast';
import {
  settingsSummary,
  slugify,
  type GalleryItem,
  type Project,
  type VoiceSettings,
} from '../../core/types';
import { SavePresetModal } from '../presets/SavePresetModal';
import { TranscriptModal } from '../stt/TranscriptModal';
import { ProjectNameModal } from '../projects/ProjectNameModal';
import { addProject, deleteProject, listProjects, renameProject } from '../projects/projectRepo';
import { AudioPlayer } from '../tts/AudioPlayer';
import { deleteGalleryItem, getGalleryAudio, listGallery, updateGalleryItem } from './galleryRepo';

function settingsOf(item: GalleryItem): VoiceSettings {
  return {
    stability: item.stability,
    similarityBoost: item.similarityBoost,
    style: item.style,
    useSpeakerBoost: item.useSpeakerBoost,
    modelId: item.modelId,
  };
}

function fmtDate(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
}

type Filter = 'all' | 'unsorted' | string; // string = projectId

interface Props {
  onEditRegenerate: (item: GalleryItem) => void;
  onUseSettings: (item: GalleryItem) => void;
}

export function GalleryScreen({ onEditRegenerate, onUseSettings }: Props) {
  const toast = useToast();
  const [items, setItems] = useState<GalleryItem[] | null>(null);
  const [projects, setProjects] = useState<Project[]>([]);
  const [filter, setFilter] = useState<Filter>('all');
  const [audioUrls, setAudioUrls] = useState<Record<string, string>>({});
  const [presetSource, setPresetSource] = useState<GalleryItem | null>(null);
  const [menuFor, setMenuFor] = useState<string | null>(null);
  const [movingItem, setMovingItem] = useState<GalleryItem | null>(null);
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState('');
  const [projectModal, setProjectModal] = useState<'create' | 'rename' | null>(null);
  const [zipping, setZipping] = useState(false);
  const [transcribingId, setTranscribingId] = useState<string | null>(null);
  const [transcriptView, setTranscriptView] = useState<GalleryItem | null>(null);

  useEffect(() => {
    let urls: string[] = [];
    listProjects()
      .then(setProjects)
      .catch((e) => {
        console.error('[Gallery] listProjects failed:', e);
        toast('Could not load projects.', 'error');
      });
    listGallery()
      .then(async (list) => {
        setItems(list);
        const map: Record<string, string> = {};
        for (const item of list) {
          const blob = await getGalleryAudio(item.id);
          if (blob) map[item.id] = URL.createObjectURL(blob);
        }
        urls = Object.values(map);
        setAudioUrls(map);
      })
      .catch((e) => {
        console.error('[Gallery] listGallery failed:', e);
        toast('Could not load your gallery.', 'error');
        setItems([]);
      });
    return () => urls.forEach((u) => URL.revokeObjectURL(u));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const activeProject = projects.find((p) => p.id === filter) ?? null;

  const visible = (items ?? []).filter((item) => {
    if (filter === 'all') return true;
    if (filter === 'unsorted') return !item.projectId;
    return item.projectId === filter;
  });

  const clipTitle = (item: GalleryItem) => item.title || item.text?.slice(0, 32) || 'Untitled';

  const downloadName = (item: GalleryItem) => {
    const project = projects.find((p) => p.id === item.projectId);
    const base = slugify(clipTitle(item));
    return project ? `${slugify(project.name)}-${base}.mp3` : `${base}.mp3`;
  };

  const remove = async (item: GalleryItem) => {
    await deleteGalleryItem(item.id);
    setItems((list) => list?.filter((i) => i.id !== item.id) ?? null);
    toast('Clip deleted.', 'info');
  };

  const commitRename = async (item: GalleryItem) => {
    const title = renameDraft.trim();
    setRenamingId(null);
    if (!title || title === clipTitle(item)) return;
    await updateGalleryItem(item.id, { title });
    setItems((list) => list?.map((i) => (i.id === item.id ? { ...i, title } : i)) ?? null);
  };

  const moveTo = async (item: GalleryItem, projectId: string | undefined) => {
    await updateGalleryItem(item.id, { projectId });
    setItems((list) => list?.map((i) => (i.id === item.id ? { ...i, projectId } : i)) ?? null);
    setMovingItem(null);
    const target = projects.find((p) => p.id === projectId)?.name ?? 'Unsorted';
    toast(`Moved to ${target}.`);
  };

  const createProject = async (name: string) => {
    const project = await addProject(name);
    setProjects((list) => [...list, project]);
    setFilter(project.id);
  };

  const renameActive = async (name: string) => {
    if (!activeProject) return;
    await renameProject(activeProject.id, name);
    setProjects((list) =>
      list.map((p) => (p.id === activeProject.id ? { ...p, name } : p)),
    );
  };

  const deleteActive = async () => {
    if (!activeProject) return;
    const count = visible.length;
    const ok = window.confirm(
      `Delete project “${activeProject.name}”? Its ${count} clip${count === 1 ? '' : 's'} will be kept in Unsorted.`,
    );
    if (!ok) return;
    await deleteProject(activeProject.id);
    setProjects((list) => list.filter((p) => p.id !== activeProject.id));
    setItems((list) =>
      list?.map((i) => (i.projectId === activeProject.id ? { ...i, projectId: undefined } : i)) ??
        null,
    );
    setFilter('all');
    toast(`Project “${activeProject.name}” deleted — clips kept in Unsorted.`, 'info');
  };

  const transcribe = async (item: GalleryItem) => {
    if (item.transcript) {
      setTranscriptView(item);
      return;
    }
    if (transcribingId) return;
    setTranscribingId(item.id);
    try {
      const blob = await getGalleryAudio(item.id);
      if (!blob) {
        toast('Audio for this clip is missing.', 'error');
        return;
      }
      const transcript = await transcribeAudio(blob, `${slugify(clipTitle(item))}.mp3`);
      await updateGalleryItem(item.id, { transcript });
      const updated = { ...item, transcript };
      setItems((list) => list?.map((i) => (i.id === item.id ? updated : i)) ?? null);
      setTranscriptView(updated);
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Transcription failed.', 'error');
    } finally {
      setTranscribingId(null);
    }
  };

  const downloadZip = async () => {
    if (zipping || visible.length === 0) return;
    setZipping(true);
    try {
      const zip = new JSZip();
      const used = new Set<string>();
      for (const item of visible) {
        const blob = await getGalleryAudio(item.id);
        if (!blob) continue;
        let name = `${slugify(clipTitle(item))}.mp3`;
        for (let n = 2; used.has(name); n++) name = `${slugify(clipTitle(item))}-${n}.mp3`;
        used.add(name);
        zip.file(name, blob);
      }
      const archive = await zip.generateAsync({ type: 'blob' });
      const zipName =
        filter === 'all' ? 'all-clips' : filter === 'unsorted' ? 'unsorted' : slugify(activeProject?.name ?? 'project');
      const url = URL.createObjectURL(archive);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${zipName}.zip`;
      a.click();
      URL.revokeObjectURL(url);
    } finally {
      setZipping(false);
    }
  };

  if (!items) return <div className="spinner" />;

  return (
    <>
      <div className="chip-row">
        <button className={`chip${filter === 'all' ? ' active' : ''}`} onClick={() => setFilter('all')}>
          All
        </button>
        <button
          className={`chip${filter === 'unsorted' ? ' active' : ''}`}
          onClick={() => setFilter('unsorted')}
        >
          Unsorted
        </button>
        {projects.map((p) => (
          <button
            key={p.id}
            className={`chip${filter === p.id ? ' active' : ''}`}
            onClick={() => setFilter(p.id)}
          >
            <Icon name="folder" /> {p.name}
          </button>
        ))}
        <button className="chip" onClick={() => setProjectModal('create')}>
          <Icon name="add" /> New project
        </button>
        <div className="chip-row-spacer" />
        {activeProject && (
          <>
            <button className="icon-btn" title="Rename project" onClick={() => setProjectModal('rename')}>
              <Icon name="edit" />
            </button>
            <button className="icon-btn" title="Delete project" onClick={deleteActive}>
              <Icon name="delete" />
            </button>
          </>
        )}
        {visible.length > 0 && (
          <button className="chip" disabled={zipping} onClick={downloadZip}>
            {zipping ? (
              'Zipping…'
            ) : (
              <>
                <Icon name="download" /> Download all (zip)
              </>
            )}
          </button>
        )}
      </div>

      {visible.length === 0 ? (
        <div className="empty-state">
          <div className="empty-icon">
            <Icon name="headphones" />
          </div>
          <h2>{filter === 'all' ? 'Nothing here yet' : 'No clips in this view'}</h2>
          <p>
            {filter === 'all'
              ? 'Generate a take in the Studio and hit “Save” on the result to keep it here.'
              : 'Save takes with this project selected in the Studio, or move existing clips here.'}
          </p>
        </div>
      ) : (
        <div className="masonry">
          {visible.map((item) => (
            <div key={item.id} className="card gallery-card">
              <div className="gallery-head">
                <div className="grow">
                  {renamingId === item.id ? (
                    <input
                      className="text-field title-input"
                      value={renameDraft}
                      onChange={(e) => setRenameDraft(e.target.value)}
                      onBlur={() => commitRename(item)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter') commitRename(item);
                        if (e.key === 'Escape') setRenamingId(null);
                      }}
                      autoFocus
                    />
                  ) : (
                    <button
                      className="clip-title"
                      title="Rename clip"
                      onClick={() => {
                        setRenameDraft(clipTitle(item));
                        setRenamingId(item.id);
                      }}
                    >
                      {clipTitle(item)}{' '}
                      <span className="rename-hint">
                        <Icon name="edit" />
                      </span>
                    </button>
                  )}
                  <div className="vtag">
                    {item.voiceName} <span className="mono">· {fmtDate(item.createdAt)}</span>
                  </div>
                </div>
                <div className="preset-menu-anchor">
                  <button
                    className="icon-btn"
                    title="More"
                    onClick={() => setMenuFor((m) => (m === item.id ? null : item.id))}
                  >
                    <Icon name="more_horiz" />
                  </button>
                  {menuFor === item.id && (
                    <div className="preset-menu">
                      <button
                        className="preset-menu-item"
                        onClick={() => {
                          setMenuFor(null);
                          setMovingItem(item);
                        }}
                      >
                        <span className="pname">Move to project…</span>
                      </button>
                      <button
                        className="preset-menu-item"
                        onClick={() => {
                          setMenuFor(null);
                          onUseSettings(item);
                        }}
                      >
                        <span className="pname">Use these settings</span>
                      </button>
                      <button
                        className="preset-menu-item"
                        onClick={() => {
                          setMenuFor(null);
                          setPresetSource(item);
                        }}
                      >
                        <span className="pname">Save as preset</span>
                      </button>
                      <button
                        className="preset-menu-item danger"
                        onClick={() => {
                          setMenuFor(null);
                          remove(item);
                        }}
                      >
                        <span className="pname">Delete</span>
                      </button>
                    </div>
                  )}
                </div>
              </div>
              <p className="gallery-text">{item.text}</p>
              <div className="vtag">{settingsSummary(settingsOf(item))}</div>
              {audioUrls[item.id] && (
                <AudioPlayer
                  src={audioUrls[item.id]}
                  downloadName={downloadName(item)}
                  autoPlay={false}
                />
              )}
              <div className="card-actions">
                <button className="chip" onClick={() => onEditRegenerate(item)}>
                  <Icon name="edit" /> Edit & regenerate
                </button>
                <button
                  className="chip"
                  disabled={transcribingId === item.id}
                  onClick={() => transcribe(item)}
                >
                  {transcribingId === item.id ? (
                    'Transcribing…'
                  ) : (
                    <>
                      <Icon name="description" /> {item.transcript ? 'Transcript' : 'Transcribe'}
                    </>
                  )}
                </button>
              </div>
            </div>
          ))}
        </div>
      )}

      {presetSource && (
        <SavePresetModal
          voiceId={presetSource.voiceId}
          voiceName={presetSource.voiceName}
          settings={settingsOf(presetSource)}
          onClose={() => setPresetSource(null)}
        />
      )}

      {transcriptView?.transcript && (
        <TranscriptModal
          title={clipTitle(transcriptView)}
          transcript={transcriptView.transcript}
          onClose={() => setTranscriptView(null)}
        />
      )}

      {projectModal && (
        <ProjectNameModal
          title={projectModal === 'create' ? 'New project' : 'Rename project'}
          initialName={projectModal === 'rename' ? activeProject?.name : undefined}
          onSubmit={projectModal === 'create' ? createProject : renameActive}
          onClose={() => setProjectModal(null)}
        />
      )}

      {movingItem && (
        <div className="modal-overlay" onClick={() => setMovingItem(null)}>
          <div className="modal small" onClick={(e) => e.stopPropagation()}>
            <div className="modal-header">
              <h2>Move to project</h2>
              <button className="icon-btn" title="Close" onClick={() => setMovingItem(null)}>
                <Icon name="close" />
              </button>
            </div>
            <div className="modal-body">
              <button
                className={`preset-menu-item${!movingItem.projectId ? ' current' : ''}`}
                onClick={() => moveTo(movingItem, undefined)}
              >
                <span className="pname">Unsorted</span>
              </button>
              {projects.map((p) => (
                <button
                  key={p.id}
                  className={`preset-menu-item${movingItem.projectId === p.id ? ' current' : ''}`}
                  onClick={() => moveTo(movingItem, p.id)}
                >
                  <span className="pname">
                    <Icon name="folder" /> {p.name}
                  </span>
                </button>
              ))}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
