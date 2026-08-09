const DB_NAME = 'kcp-offline-v1'
const DB_VERSION = 1
const ACTION_STORE = 'actions'
const SNAPSHOT_STORE = 'snapshots'
const FALLBACK_ACTION_KEY = 'kcp.offline.actions'
const FALLBACK_SNAPSHOT_KEY = 'kcp.offline.snapshots'

export function createOfflineAction({
  id = cryptoSafeId(),
  tripId,
  groupId = null,
  action,
  payload = {},
  deviceTimestamp = new Date().toISOString(),
  createdAt = new Date().toISOString()
}) {
  if (!tripId || !action) throw new Error('Trip and action are required')
  return {
    id,
    tripId,
    groupId,
    action,
    payload: payload || {},
    deviceTimestamp,
    createdAt,
    updatedAt: createdAt,
    status: 'pending',
    attempts: 0,
    lastError: null
  }
}

export function sortOfflineActions(actions = []) {
  return [...actions].sort((left, right) =>
    String(left.createdAt).localeCompare(String(right.createdAt))
      || String(left.id).localeCompare(String(right.id))
  )
}

export function nextSyncBatch(actions = [], limit = 50) {
  const blockedTrips = new Set(
    actions.filter(action => action.status === 'failed').map(action => action.tripId)
  )
  return sortOfflineActions(actions)
    .filter(action => action.status === 'pending' && !blockedTrips.has(action.tripId))
    .slice(0, Math.max(1, limit))
}

export async function enqueueOfflineAction(input) {
  const action = input?.id ? input : createOfflineAction(input)
  await putRecord(ACTION_STORE, action)
  return action
}

export async function listOfflineActions() {
  return sortOfflineActions(await getAllRecords(ACTION_STORE))
}

export async function updateOfflineAction(id, patch) {
  const actions = await listOfflineActions()
  const existing = actions.find(action => action.id === id)
  if (!existing) return null
  const updated = {
    ...existing,
    ...patch,
    id: existing.id,
    updatedAt: new Date().toISOString()
  }
  await putRecord(ACTION_STORE, updated)
  return updated
}

export async function removeOfflineAction(id) {
  await deleteRecord(ACTION_STORE, id)
}

export async function clearCompletedOfflineActions() {
  const actions = await listOfflineActions()
  await Promise.all(actions.filter(action => action.status === 'completed').map(action => removeOfflineAction(action.id)))
}

export async function cacheDriverSnapshot(tripId, snapshot, ttlMinutes = 24 * 60) {
  if (!tripId || !snapshot) return
  const now = Date.now()
  await putRecord(SNAPSHOT_STORE, {
    id: tripId,
    tripId,
    snapshot,
    cachedAt: new Date(now).toISOString(),
    expiresAt: new Date(now + ttlMinutes * 60 * 1000).toISOString()
  })
}

export async function loadDriverSnapshot(tripId) {
  const snapshots = await getAllRecords(SNAPSHOT_STORE)
  const row = snapshots.find(snapshot => snapshot.tripId === tripId)
  if (!row) return null
  if (new Date(row.expiresAt).getTime() <= Date.now()) {
    await deleteRecord(SNAPSHOT_STORE, row.id)
    return null
  }
  return row.snapshot
}

export async function clearExpiredDriverSnapshots() {
  const snapshots = await getAllRecords(SNAPSHOT_STORE)
  await Promise.all(
    snapshots
      .filter(snapshot => new Date(snapshot.expiresAt).getTime() <= Date.now())
      .map(snapshot => deleteRecord(SNAPSHOT_STORE, snapshot.id))
  )
}

async function openDatabase() {
  if (!globalThis.indexedDB) return null
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION)
    request.onupgradeneeded = () => {
      const database = request.result
      if (!database.objectStoreNames.contains(ACTION_STORE)) {
        const actions = database.createObjectStore(ACTION_STORE, { keyPath: 'id' })
        actions.createIndex('status', 'status', { unique: false })
        actions.createIndex('tripId', 'tripId', { unique: false })
        actions.createIndex('createdAt', 'createdAt', { unique: false })
      }
      if (!database.objectStoreNames.contains(SNAPSHOT_STORE)) {
        database.createObjectStore(SNAPSHOT_STORE, { keyPath: 'id' })
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

async function putRecord(storeName, value) {
  const database = await openDatabase().catch(() => null)
  if (!database) return fallbackPut(storeName, value)
  await transactionPromise(database, storeName, 'readwrite', store => store.put(value))
  database.close()
}

async function getAllRecords(storeName) {
  const database = await openDatabase().catch(() => null)
  if (!database) return fallbackGetAll(storeName)
  const values = await transactionPromise(database, storeName, 'readonly', store => store.getAll())
  database.close()
  return values || []
}

async function deleteRecord(storeName, id) {
  const database = await openDatabase().catch(() => null)
  if (!database) return fallbackDelete(storeName, id)
  await transactionPromise(database, storeName, 'readwrite', store => store.delete(id))
  database.close()
}

function transactionPromise(database, storeName, mode, operation) {
  return new Promise((resolve, reject) => {
    const transaction = database.transaction(storeName, mode)
    const request = operation(transaction.objectStore(storeName))
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
    transaction.onerror = () => reject(transaction.error)
  })
}

function fallbackKey(storeName) {
  return storeName === ACTION_STORE ? FALLBACK_ACTION_KEY : FALLBACK_SNAPSHOT_KEY
}
function fallbackGetAll(storeName) {
  try {
    return JSON.parse(globalThis.localStorage?.getItem(fallbackKey(storeName)) || '[]')
  } catch {
    return []
  }
}
function fallbackPut(storeName, value) {
  const values = fallbackGetAll(storeName)
  const index = values.findIndex(item => item.id === value.id)
  if (index >= 0) values[index] = value
  else values.push(value)
  globalThis.localStorage?.setItem(fallbackKey(storeName), JSON.stringify(values))
}
function fallbackDelete(storeName, id) {
  const values = fallbackGetAll(storeName).filter(item => item.id !== id)
  globalThis.localStorage?.setItem(fallbackKey(storeName), JSON.stringify(values))
}
function cryptoSafeId() {
  return globalThis.crypto?.randomUUID?.() || `offline-${Date.now()}-${Math.random().toString(16).slice(2)}`
}
