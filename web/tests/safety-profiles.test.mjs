import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'

const source = fs.readFileSync('web/app.parts/24-safety-profiles.js', 'utf8')
const migration = fs.readFileSync('supabase/migrations/202608080005_kcp_safety_profiles_vehicles.sql', 'utf8')
const worker = fs.readFileSync('web/service-worker-v24.js', 'utf8')

test('child safety profile captures only transportation-critical details', () => {
  assert.match(migration, /kcp_child_safety_profiles/)
  assert.match(migration, /pickup_address/)
  assert.match(migration, /authorized_pickup_people/)
  assert.match(migration, /seat_requirement/)
  assert.match(migration, /critical_alert/)
  assert.match(source, /Important information for the driver/)
  assert.match(source, /assigned driver during the ride window/)
})

test('driver readiness includes license, insurance, safety terms and vehicle capacity', () => {
  assert.match(migration, /kcp_driver_safety_profiles/)
  assert.match(migration, /license_acknowledged_at/)
  assert.match(migration, /insurance_acknowledged_at/)
  assert.match(migration, /kcp_vehicles/)
  assert.match(source, /vehicleSeatCapacity/)
  assert.match(source, /vehicleBoosterCapacity/)
  assert.match(source, /vehicleCarSeatCapacity/)
})

test('capacity check counts seats, boosters and car-seat positions', () => {
  assert.match(migration, /kcp_trip_capacity_status/)
  assert.match(migration, /required_boosters/)
  assert.match(migration, /required_car_seats/)
  assert.match(source, /Vehicle capacity compatible/)
  assert.match(source, /Driving readiness needs attention/)
})

test('Viewer settings do not render family safety controls', () => {
  assert.match(source, /if \(access\.isViewer\) return/)
})

test('installed app refreshes safety-profile assets', () => {
  assert.match(worker, /v24-offline-accessibility/)
  assert.match(worker, /\.\/safety-profiles\.css/)
})
