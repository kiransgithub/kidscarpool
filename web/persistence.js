const DB_NAME = 'kcp-pilot-persistence'
const DB_VERSION = 1
const STORE_NAME = 'key-value'
const DEVICE_LINKS_KEY = 'kcp.deviceLinks.v1'

function memorySafeLocalStorage(candidate) {
  if (!candidate) return null
  try {
    const testKey = '__kcp_storage_test__'
    candidate.setItem(testKey, '1')
    candidate.removeItem(testKey)
    return candidate
  } catch {
    return null
  }
}

function openDatabase(indexedDBRef) {
  if (!indexedDBRef) return Promise.resolve(null)

  return new Promise(resolve => {
    let request
    try {
      request = indexedDBRef.open(DB_NAME, DB_VERSION)
    } catch {
      resolve(null)
      return
    }

    request.onupgradeneeded = () => {
      const database = request.result
      if (!database.objectStoreNames.contains(STORE_NAME)) {
        database.createObjectStore(STORE_NAME)
      }
    }
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => resolve(null)
    request.onblocked = () => resolve(null)
  })
}

async function indexedGet(indexedDBRef, key) {
  const database = await openDatabase(indexedDBRef)
  if (!database) return null

  return new Promise(resolve => {
    try {
      const transaction = database.transaction(STORE_NAME, 'readonly')
      const request = transaction.objectStore(STORE_NAME).get(key)
      request.onsuccess = () => resolve(request.result ?? null)
      request.onerror = () => resolve(null)
      transaction.oncomplete = () => database.close()
      transaction.onerror = () => {
        database.close()
        resolve(null)
      }
    } catch {
      database.close()
      resolve(null)
    }
  })
}

async function indexedSet(indexedDBRef, key, value) {
  const database = await openDatabase(indexedDBRef)
  if (!database) return

  await new Promise(resolve => {
    try {
      const transaction = database.transaction(STORE_NAME, 'readwrite')
      transaction.objectStore(STORE_NAME).put(value, key)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => resolve()
      transaction.onabort = () => resolve()
    } catch {
      resolve()
    }
  })
  database.close()
}

async function indexedRemove(indexedDBRef, key) {
  const database = await openDatabase(indexedDBRef)
  if (!database) return

  await new Promise(resolve => {
    try {
      const transaction = database.transaction(STORE_NAME, 'readwrite')
      transaction.objectStore(STORE_NAME).delete(key)
      transaction.oncomplete = () => resolve()
      transaction.onerror = () => resolve()
      transaction.onabort = () => resolve()
    } catch {
      resolve()
    }
  })
  database.close()
}

export function createHybridStorage({
  indexedDBRef = globalThis.indexedDB,
  localStorageRef = globalThis.localStorage
} = {}) {
  const local = memorySafeLocalStorage(localStorageRef)

  return {
    async getItem(key) {
      const indexed = await indexedGet(indexedDBRef, key)
      if (indexed !== null && indexed !== undefined) return String(indexed)

      if (!local) return null
      const fallback = local.getItem(key)
      if (fallback !== null) await indexedSet(indexedDBRef, key, fallback)
      return fallback
    },

    async setItem(key, value) {
      const serialized = String(value)
      if (local) {
        try { local.setItem(key, serialized) } catch { /* IndexedDB remains primary. */ }
      }
      await indexedSet(indexedDBRef, key, serialized)
    },

    async removeItem(key) {
      if (local) {
        try { local.removeItem(key) } catch { /* Best effort. */ }
      }
      await indexedRemove(indexedDBRef, key)
    }
  }
}

export const kcpAuthStorage = createHybridStorage()

export async function loadDeviceLinks(storage = kcpAuthStorage) {
  const raw = await storage.getItem(DEVICE_LINKS_KEY)
  if (!raw) return []

  try {
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter(item => item && item.groupId && item.secret)
  } catch {
    return []
  }
}

export async function saveDeviceLink(link, storage = kcpAuthStorage) {
  if (!link?.groupId || !link?.secret) {
    throw new TypeError('A groupId and device secret are required')
  }

  const existing = await loadDeviceLinks(storage)
  const next = [
    ...existing.filter(item => item.groupId !== link.groupId),
    {
      groupId: String(link.groupId),
      secret: String(link.secret),
      createdAt: link.createdAt || new Date().toISOString()
    }
  ]
  await storage.setItem(DEVICE_LINKS_KEY, JSON.stringify(next))
  return next
}

export async function removeDeviceLink(groupId, storage = kcpAuthStorage) {
  const existing = await loadDeviceLinks(storage)
  const next = existing.filter(item => item.groupId !== groupId)
  await storage.setItem(DEVICE_LINKS_KEY, JSON.stringify(next))
  return next
}

export async function clearDeviceLinks(storage = kcpAuthStorage) {
  await storage.removeItem(DEVICE_LINKS_KEY)
}

export { DEVICE_LINKS_KEY }
