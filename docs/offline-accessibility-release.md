# Offline ride actions, accessibility and release hardening

## Offline Driver mode

Open an imminent ride once while online. KCP caches the operational snapshot on that device for up to 24 hours.

When connectivity is unavailable, Driver mode can save:

```text
Confirm ride
Start ride
Child picked up
Child not riding
Arrived at destination
Confirm completion
Report issue
```

Actions are stored in IndexedDB, with local storage as a fallback. Each action has a unique client ID and device timestamp.

## Ordered synchronization

```text
Original action order
  → authenticated replay RPC
  → unique server receipt
  → underlying trip event
  → local action removed
```

A failed action blocks later actions for the same ride so the server never sees Child picked up before Start. Actions for another ride may continue.

The server uses an advisory transaction lock and a unique `(user_id, client_action_id)` receipt. Retrying after a timeout cannot apply an action twice.

An offline Start may synchronize after the normal server window only when the saved device timestamp was within 10 minutes before through 90 minutes after the scheduled time and is not implausibly in the future.

## Conflict handling

A rejected replay remains visible under More/Settings with a user-safe explanation. The driver can:

```text
Retry
or
Discard
```

Discarding requires confirmation and means the action will not be added to the group record.

## Offline status

The app visibly distinguishes:

```text
Offline
Syncing
Sync needs attention
```

It never claims that a locally queued completion is a verified server completion. Driver mode displays **Completion saved offline · waiting to sync** until replay succeeds.

## Accessibility contract

- Skip to main content
- 44-point minimum controls
- visible keyboard focus
- dialog labels and modal semantics
- text plus icon for status
- reduced-motion support
- higher-contrast border support
- light and dark appearance
- responsive queue and driver controls

## Release service worker

`service-worker-v24.js` replaces the older pilot worker for the same scope. It provides:

- offline navigation fallback
- current application shell caching
- network-first updates
- Web Push display and click routing
- cleanup of older KCP caches

## Manual validation

1. Open a test ride online in Driver mode.
2. Enable Airplane Mode.
3. Confirm and start the ride; account for children; report arrival and completion.
4. Reconnect.
5. Verify actions sync in order and only one event exists for each client ID.
6. Force a stale/invalid action and verify it is shown as failed rather than silently discarded.
7. Test VoiceOver, 200% browser text size, light/dark appearance and Reduce Motion.
