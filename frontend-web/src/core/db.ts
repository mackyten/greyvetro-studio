/** Shared IndexedDB access for the gallery + projects + scenes + timelines stores. */

const DB_NAME = 'greyvetro-studio';
// Pre-rename database name (repo was `greyvetro-stt`) — kept only so migrateFromOldDb
// can carry existing browser data over once; never opened for anything else.
const OLD_DB_NAME = 'greyvetro-tts';
const VERSION = 5;
const MIGRATION_FLAG = 'greyvetro-studio-db-migrated';

export const GALLERY_STORE = 'gallery';
export const PROJECT_STORE = 'projects';
export const SCENE_STORE = 'scenes';
export const TIMELINE_STORE = 'timelines';
export const TIMELINE_ASSET_STORE = 'timelineAssets';

const ALL_STORES = [GALLERY_STORE, PROJECT_STORE, SCENE_STORE, TIMELINE_STORE, TIMELINE_ASSET_STORE];

function openRaw(name: string, version?: number): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = version ? indexedDB.open(name, version) : indexedDB.open(name);
    req.onupgradeneeded = () => {
      const db = req.result;
      for (const store of ALL_STORES) {
        if (!db.objectStoreNames.contains(store)) db.createObjectStore(store, { keyPath: 'id' });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function getAllRows(db: IDBDatabase, store: string): Promise<unknown[]> {
  return new Promise((resolve, reject) => {
    if (!db.objectStoreNames.contains(store)) {
      resolve([]);
      return;
    }
    const req = db.transaction(store, 'readonly').objectStore(store).getAll();
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

// One-time carry-over from the pre-rename `greyvetro-tts` database so a browser that
// already had gallery/project/scene/timeline data doesn't lose it under the new name.
async function migrateFromOldDb(newDb: IDBDatabase): Promise<void> {
  if (localStorage.getItem(MIGRATION_FLAG)) return;
  const hasOldDb =
    typeof indexedDB.databases === 'function' &&
    (await indexedDB.databases()).some((d) => d.name === OLD_DB_NAME);
  if (!hasOldDb) {
    localStorage.setItem(MIGRATION_FLAG, '1');
    return;
  }
  const oldDb = await openRaw(OLD_DB_NAME);
  for (const store of ALL_STORES) {
    const rows = await getAllRows(oldDb, store);
    if (rows.length === 0) continue;
    const tx = newDb.transaction(store, 'readwrite');
    const os = tx.objectStore(store);
    for (const row of rows) os.put(row);
    await txDone(tx);
  }
  oldDb.close();
  localStorage.setItem(MIGRATION_FLAG, '1');
}

export async function openDb(): Promise<IDBDatabase> {
  const db = await openRaw(DB_NAME, VERSION);
  try {
    await migrateFromOldDb(db);
  } catch (e) {
    console.error('[db] migrateFromOldDb failed, continuing without migration:', e);
  }
  return db;
}

export function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error);
  });
}
