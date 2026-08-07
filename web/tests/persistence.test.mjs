import test from 'node:test'
import assert from 'node:assert/strict'
import {
  createHybridStorage,
  loadDeviceLinks,
  saveDeviceLink,
  removeDeviceLink
} from '../persistence.js'

function memoryStorage() {
  const values = new Map()
  return {
    getItem(key) { return values.has(key) ? values.get(key) : null },
    setItem(key, value) { values.set(key, String(value)) },
    removeItem(key) { values.delete(key) }
  }
}

test('hybrid storage falls back to durable local storage when IndexedDB is unavailable', async () => {
  const localStorageRef = memoryStorage()
  const storage = createHybridStorage({ indexedDBRef: null, localStorageRef })

  await storage.setItem('session', '{"refresh_token":"abc"}')
  assert.equal(await storage.getItem('session'), '{"refresh_token":"abc"}')

  await storage.removeItem('session')
  assert.equal(await storage.getItem('session'), null)
})

test('one remembered device credential is retained per group', async () => {
  const storage = createHybridStorage({ indexedDBRef: null, localStorageRef: memoryStorage() })

  await saveDeviceLink({ groupId: 'group-a', secret: 'first' }, storage)
  await saveDeviceLink({ groupId: 'group-b', secret: 'second' }, storage)
  await saveDeviceLink({ groupId: 'group-a', secret: 'replacement' }, storage)

  const links = await loadDeviceLinks(storage)
  assert.equal(links.length, 2)
  assert.equal(links.find(item => item.groupId === 'group-a').secret, 'replacement')
  assert.equal(links.find(item => item.groupId === 'group-b').secret, 'second')
})

test('removing one group credential leaves the others intact', async () => {
  const storage = createHybridStorage({ indexedDBRef: null, localStorageRef: memoryStorage() })

  await saveDeviceLink({ groupId: 'group-a', secret: 'one' }, storage)
  await saveDeviceLink({ groupId: 'group-b', secret: 'two' }, storage)
  const remaining = await removeDeviceLink('group-a', storage)

  assert.deepEqual(remaining.map(item => item.groupId), ['group-b'])
  assert.deepEqual((await loadDeviceLinks(storage)).map(item => item.groupId), ['group-b'])
})
