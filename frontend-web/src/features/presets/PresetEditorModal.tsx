import { useState } from 'react';
import { Icon } from '../../core/Icon';
import { useToast } from '../../core/toast';
import {
  defaultSettings,
  DEFAULT_MODEL_ID,
  MODELS,
  type Preset,
  type Voice,
  type VoiceSettings,
} from '../../core/types';
import { VoicePickerModal } from '../voices/VoicePickerModal';
import { findMatchingPreset, updatePreset } from './presetRepo';

interface SliderProps {
  label: string;
  value: number;
  onChange: (v: number) => void;
}

function SettingSlider({ label, value, onChange }: SliderProps) {
  return (
    <div className="slider-row">
      <div className="slider-head">
        <span>{label}</span>
        <span className="val">{value.toFixed(2)}</span>
      </div>
      <input
        type="range"
        min={0}
        max={1}
        step={0.05}
        value={value}
        onChange={(e) => onChange(parseFloat(e.target.value))}
      />
    </div>
  );
}

interface Props {
  preset: Preset;
  onSaved: () => void;
  onClose: () => void;
}

export function PresetEditorModal({ preset, onSaved, onClose }: Props) {
  const toast = useToast();
  const [name, setName] = useState(preset.name);
  const [voiceId, setVoiceId] = useState(preset.voiceId);
  const [voiceName, setVoiceName] = useState(preset.voiceName);
  const [settings, setSettings] = useState<VoiceSettings>({
    stability: preset.stability ?? defaultSettings.stability,
    similarityBoost: preset.similarityBoost ?? defaultSettings.similarityBoost,
    style: preset.style ?? defaultSettings.style,
    useSpeakerBoost: preset.useSpeakerBoost ?? defaultSettings.useSpeakerBoost,
    modelId: preset.modelId ?? DEFAULT_MODEL_ID,
  });
  const [pickerOpen, setPickerOpen] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const savePreset = () => {
    if (!name.trim()) return;
    const existing = findMatchingPreset(voiceId, settings, preset.id);
    if (existing) {
      setError(`These settings are already saved as “${existing.name}”.`);
      return;
    }
    updatePreset({ ...preset, name: name.trim(), voiceId, voiceName, ...settings });
    toast(`Preset “${name.trim()}” updated.`);
    onSaved();
    onClose();
  };

  const onPickVoice = (v: Voice) => {
    setVoiceId(v.id);
    setVoiceName(v.name);
    setPickerOpen(false);
    setError(null);
  };

  return (
    <>
      <div className="modal-overlay" onClick={onClose}>
        <div className="modal small" onClick={(e) => e.stopPropagation()}>
          <div className="modal-header">
            <h2>Edit preset</h2>
            <button className="icon-btn" title="Close" onClick={onClose}>
              <Icon name="close" />
            </button>
          </div>
          <div className="modal-body">
            <input
              className="text-field"
              placeholder="Preset name"
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
            <button className="voice-button" onClick={() => setPickerOpen(true)}>
              <div className="voice-avatar">{voiceName.charAt(0).toUpperCase()}</div>
              <div>
                <div className="vname">{voiceName}</div>
                <div className="vtag">Tap to change voice</div>
              </div>
            </button>
            <select
              className="text-field"
              value={settings.modelId ?? DEFAULT_MODEL_ID}
              onChange={(e) => setSettings((s) => ({ ...s, modelId: e.target.value }))}
            >
              {MODELS.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.label}
                </option>
              ))}
            </select>
            <SettingSlider
              label="Stability"
              value={settings.stability}
              onChange={(v) => setSettings((s) => ({ ...s, stability: v }))}
            />
            <SettingSlider
              label="Similarity"
              value={settings.similarityBoost}
              onChange={(v) => setSettings((s) => ({ ...s, similarityBoost: v }))}
            />
            <SettingSlider
              label="Style"
              value={settings.style}
              onChange={(v) => setSettings((s) => ({ ...s, style: v }))}
            />
            <div className="switch-row">
              <span>Speaker boost</span>
              <button
                className={`switch${settings.useSpeakerBoost ? ' on' : ''}`}
                role="switch"
                aria-checked={settings.useSpeakerBoost}
                onClick={() => setSettings((s) => ({ ...s, useSpeakerBoost: !s.useSpeakerBoost }))}
              />
            </div>
            {error && <div className="error-banner">{error}</div>}
            <button className="generate-btn" disabled={!name.trim()} onClick={savePreset}>
              Save changes
            </button>
          </div>
        </div>
      </div>

      {pickerOpen && (
        <VoicePickerModal
          selectedId={voiceId}
          onSelect={onPickVoice}
          onClose={() => setPickerOpen(false)}
        />
      )}
    </>
  );
}
