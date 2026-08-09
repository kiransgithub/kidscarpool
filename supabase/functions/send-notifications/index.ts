import { createClient } from 'npm:@supabase/supabase-js@2.57.4'
import webpush from 'npm:web-push@3.6.7'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-kcp-dispatch-secret'
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })

  const dispatchSecret = Deno.env.get('NOTIFICATION_DISPATCH_SECRET')
  if (!dispatchSecret || request.headers.get('x-kcp-dispatch-secret') !== dispatchSecret) {
    return json({ error: 'Unauthorized' }, 401)
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRole = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  const publicKey = Deno.env.get('VAPID_PUBLIC_KEY')
  const privateKey = Deno.env.get('VAPID_PRIVATE_KEY')
  const subject = Deno.env.get('VAPID_SUBJECT') || 'mailto:support@example.com'
  if (!supabaseUrl || !serviceRole || !publicKey || !privateKey) {
    return json({ error: 'Notification secrets are incomplete' }, 500)
  }

  webpush.setVapidDetails(subject, publicKey, privateKey)
  const supabase = createClient(supabaseUrl, serviceRole, {
    auth: { persistSession: false, autoRefreshToken: false }
  })

  const now = new Date().toISOString()
  const { data: pending, error: pendingError } = await supabase
    .from('kcp_notification_outbox')
    .select('*')
    .in('status', ['pending', 'failed'])
    .lte('not_before', now)
    .lt('attempts', 6)
    .order('created_at')
    .limit(50)
  if (pendingError) return json({ error: pendingError.message }, 500)
  if (!pending?.length) return json({ processed: 0, delivered: 0, failed: 0 })

  let delivered = 0
  let failed = 0
  let processed = 0

  for (const item of pending) {
    const { data: claimed } = await supabase
      .from('kcp_notification_outbox')
      .update({ status: 'processing', locked_at: now, attempts: item.attempts + 1 })
      .eq('id', item.id)
      .in('status', ['pending', 'failed'])
      .select('id')
      .maybeSingle()
    if (!claimed) continue

    const { data: subscriptions, error: subscriptionError } = await supabase
      .from('kcp_push_subscriptions')
      .select('*')
      .eq('user_id', item.target_user_id)
      .is('revoked_at', null)

    if (subscriptionError) {
      await markOutbox(supabase, item.id, 'failed', subscriptionError.message)
      failed += 1
      continue
    }

    if (!subscriptions?.length) {
      await markOutbox(supabase, item.id, 'failed', 'No active push subscription')
      failed += 1
      continue
    }

    let sentForItem = 0
    let failedForItem = 0
    const payload = JSON.stringify({
      title: item.title,
      body: item.body,
      url: item.target_url,
      category: item.category,
      groupId: item.group_id,
      tripId: item.trip_id,
      ...item.payload
    })

    for (const subscription of subscriptions) {
      try {
        await webpush.sendNotification({
          endpoint: subscription.endpoint,
          keys: { p256dh: subscription.p256dh, auth: subscription.auth_secret }
        }, payload, { TTL: 3600, urgency: urgencyFor(item.category) })

        await supabase.from('kcp_notification_deliveries').insert({
          outbox_id: item.id,
          subscription_id: subscription.id,
          status: 'sent'
        })
        await supabase.from('kcp_push_subscriptions').update({ last_used_at: new Date().toISOString() }).eq('id', subscription.id)
        sentForItem += 1
        delivered += 1
      } catch (error) {
        const statusCode = Number(error?.statusCode || error?.status || 0) || null
        const gone = statusCode === 404 || statusCode === 410
        await supabase.from('kcp_notification_deliveries').insert({
          outbox_id: item.id,
          subscription_id: subscription.id,
          status: gone ? 'gone' : 'failed',
          response_code: statusCode,
          error_message: String(error?.message || error).slice(0, 500)
        })
        if (gone) {
          await supabase.from('kcp_push_subscriptions').update({ revoked_at: new Date().toISOString() }).eq('id', subscription.id)
        }
        failedForItem += 1
        failed += 1
      }
    }

    const finalStatus = sentForItem > 0
      ? failedForItem > 0 ? 'partial' : 'sent'
      : 'failed'
    await markOutbox(
      supabase,
      item.id,
      finalStatus,
      failedForItem ? `${failedForItem} subscription delivery failure(s)` : null
    )
    processed += 1
  }

  return json({ processed, delivered, failed })
})

async function markOutbox(supabase: ReturnType<typeof createClient>, id: string, status: string, error: string | null) {
  await supabase.from('kcp_notification_outbox').update({
    status,
    last_error: error,
    processed_at: ['sent', 'partial'].includes(status) ? new Date().toISOString() : null,
    locked_at: null
  }).eq('id', id)
}

function urgencyFor(category: string) {
  if (['cover_escalated', 'trip_unconfirmed', 'driver_confirmation_due'].includes(category)) return 'high'
  if (['cover_requested', 'child_absence', 'completion_due', 'swap_requested'].includes(category)) return 'normal'
  return 'low'
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  })
}
