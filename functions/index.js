const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

// West→East processing order across US states (used by schedulers)
const WEST_TO_EAST_STATE_ORDER = [
  'AK', 'HI',
  'CA', 'OR', 'WA',
  'NV', 'AZ', 'ID', 'UT',
  'NM', 'CO', 'MT', 'WY',
  'ND', 'SD', 'NE', 'KS', 'OK', 'TX',
  'MN', 'IA', 'MO', 'AR', 'LA',
  'WI', 'IL', 'MS', 'MI', 'IN', 'KY', 'TN', 'AL', 'GA', 'FL',
  'OH', 'WV', 'VA', 'NC', 'SC',
  'PA', 'NY', 'MD', 'DE', 'NJ', 'CT', 'RI', 'MA', 'VT', 'NH', 'ME', 'DC'
];

// Map state code to ISO3166-2 identifier (kept for validation; OSM removed)
const STATE_ISO_MAP = {
  AL: 'US-AL', AK: 'US-AK', AZ: 'US-AZ', AR: 'US-AR', CA: 'US-CA', CO: 'US-CO',
  CT: 'US-CT', DE: 'US-DE', DC: 'US-DC', FL: 'US-FL', GA: 'US-GA', HI: 'US-HI',
  ID: 'US-ID', IL: 'US-IL', IN: 'US-IN', IA: 'US-IA', KS: 'US-KS', KY: 'US-KY',
  LA: 'US-LA', ME: 'US-ME', MD: 'US-MD', MA: 'US-MA', MI: 'US-MI', MN: 'US-MN',
  MS: 'US-MS', MO: 'US-MO', MT: 'US-MT', NE: 'US-NE', NV: 'US-NV', NH: 'US-NH',
  NJ: 'US-NJ', NM: 'US-NM', NY: 'US-NY', NC: 'US-NC', ND: 'US-ND', OH: 'US-OH',
  OK: 'US-OK', OR: 'US-OR', PA: 'US-PA', RI: 'US-RI', SC: 'US-SC', SD: 'US-SD',
  TN: 'US-TN', TX: 'US-TX', UT: 'US-UT', VT: 'US-VT', VA: 'US-VA', WA: 'US-WA',
  WV: 'US-WV', WI: 'US-WI', WY: 'US-WY'
};

// Queue inactivity timeout (minutes)
const QUEUE_TIMEOUT_MINUTES = 60;

// Cached admin UID for short-lived reuse
let cachedAdminUid = null;
let cachedAt = 0;
const ADMIN_CACHE_MS = 5 * 60 * 1000; // 5 minutes

/**
 * Reads the single admin UID from Firestore config.
 * Place a document at config/app with a field adminUid: "<owner uid>".
 */
async function getAdminUid(db) {
  const now = Date.now();
  if (cachedAdminUid && (now - cachedAt) < ADMIN_CACHE_MS) {
    return cachedAdminUid;
  }
  try {
    const doc = await db.collection('config').doc('app').get();
    const uid = doc.exists ? doc.data().adminUid : null;
    cachedAdminUid = uid || null;
    cachedAt = Date.now();
    if (!uid) {
      console.warn('config/app.adminUid is not set. All users will be treated as non-admin.');
    }
    return cachedAdminUid;
  } catch (e) {
    console.error('Error reading adminUid from config/app:', e);
    cachedAdminUid = null;
    cachedAt = Date.now();
    return null;
  }
}

/**
 * Firestore trigger: enforce that only the configured admin UID can have isAdmin == true.
 * If any other user is written with isAdmin true, it will be reverted to false.
 */
exports.enforceSingleAdminOnUserWrite = functions.firestore
  .document('users/{userId}')
  .onWrite(async (change, context) => {
    const db = admin.firestore();
    const userId = context.params.userId;
    const after = change.after.exists ? change.after.data() : null;
    if (!after) return null; // ignore deletes

    try {
      const adminUid = await getAdminUid(db);
      const isAdmin = !!after.isAdmin;

      // If adminUid is not set, force everyone to non-admin
      if (!adminUid && isAdmin) {
        console.log(`Admin UID not configured. Stripping isAdmin from ${userId}.`);
        await change.after.ref.update({ isAdmin: false, updatedAt: new Date().toISOString() });
        return null;
      }

      if (adminUid && userId !== adminUid && isAdmin) {
        console.log(`User ${userId} attempted to have admin rights; reverting.`);
        await change.after.ref.update({ isAdmin: false, updatedAt: new Date().toISOString() });
      }
      // If the owner document accidentally loses admin, auto-correct to true
      if (adminUid && userId === adminUid && !isAdmin) {
        console.log(`Owner ${userId} lost admin flag; restoring.`);
        await change.after.ref.update({ isAdmin: true, updatedAt: new Date().toISOString() });
      }
      return null;
    } catch (e) {
      console.error('Error enforcing single admin:', e);
      return null;
    }
  });

/**
 * Server-side: Fix City/State from Address (zero-API, resumable)
 * Mirrors the client ParkBackfillService.fixCityFromAddress but runs on Cloud Functions.
 * Writes heartbeat and totals to jobs/fix_city_from_address so Admin UI can track progress.
 */
async function runFixCityFromAddressBatch(db, { pageSize = 1200, resume = true } = {}) {
  let scanned = 0;
  let updated = 0;
  let skippedEmpty = 0;
  let ambiguous = 0;

  pageSize = Math.max(200, Math.min(1500, Number(pageSize) || 1200));

  const ckptRef = db.collection('jobs').doc('fix_city_from_address');
  let cursorId = null;
  let totals = { pages: 0, scanned: 0, updated: 0, skippedEmpty: 0, ambiguous: 0 };
  if (resume) {
    try {
      const ck = await ckptRef.get();
      if (ck.exists) {
        const d = ck.data() || {};
        cursorId = d.lastDocId || null;
        totals.pages = Number(d.pages || 0);
        totals.scanned = Number(d.scanned || 0);
        totals.updated = Number(d.updated || 0);
        totals.skippedEmpty = Number(d.skippedEmpty || 0);
        totals.ambiguous = Number(d.ambiguous || 0);
      }
    } catch (_) {}
  } else {
    // Clear previous run totals
    try {
      await ckptRef.set({ status: 'in_progress', lastDocId: null, pages: 0, scanned: 0, updated: 0, skippedEmpty: 0, ambiguous: 0, lastHeartbeatAt: new Date().toISOString() }, { merge: true });
    } catch (_) {}
  }

  let base = db.collection('parks').orderBy(admin.firestore.FieldPath.documentId());
  if (cursorId) {
    try {
      const cur = await db.collection('parks').doc(cursorId).get();
      if (cur.exists) base = base.startAfter(cur);
    } catch (_) {}
  }

  const snap = await base.limit(pageSize).get();
  if (snap.empty) {
    // Nothing to scan; mark done
    try {
      await ckptRef.set({ status: 'done', completedAt: new Date().toISOString() }, { merge: true });
    } catch (_) {}
    return { pageScanned: 0, pageUpdated: 0, pageSkippedEmpty: 0, pageAmbiguous: 0, done: true, cursor: null, ...totals };
  }

  let batch = db.batch();
  let writes = 0;
  const commit = async () => { if (writes > 0) { await batch.commit(); batch = db.batch(); writes = 0; } };

  const docs = snap.docs;
  for (const doc of docs) {
    scanned += 1;
    const d = doc.data() || {};
    const id = doc.id;
    const addr = String(d.address || '').trim();
    if (!addr || addr.toLowerCase() === 'address not specified') { skippedEmpty += 1; continue; }

    const parsed = parseCityStateFromAddress(addr);
    const parsedCity = String(parsed.city || '').trim();
    const parsedState = String(parsed.state || '').trim();
    if (!parsedCity || !parsedState) { ambiguous += 1; continue; }

    const currentCity = String(d.city || '').trim();
    const currentStateCanon = canonState(String(d.state || '').trim());
    const needCity = !currentCity || currentCity.toLowerCase() !== parsedCity.toLowerCase();
    const needState = !currentStateCanon || currentStateCanon !== parsedState;
    if (!needCity && !needState) continue;

    const update = {
      city: titleCase(parsedCity),
      state: parsedState,
      updatedAt: new Date().toISOString(),
    };
    batch.update(db.collection('parks').doc(id), update);
    writes += 1;
    updated += 1;
    if (writes >= 400) await commit();
  }

  await commit();
  const newCursor = docs[docs.length - 1].id;
  const isLast = docs.length < pageSize;

  // Update cumulative totals in checkpoint
  const nowIso = new Date().toISOString();
  const newTotals = {
    pages: totals.pages + 1,
    scanned: totals.scanned + scanned,
    updated: totals.updated + updated,
    skippedEmpty: totals.skippedEmpty + skippedEmpty,
    ambiguous: totals.ambiguous + ambiguous,
  };
  try {
    await ckptRef.set({
      status: isLast ? 'done' : 'in_progress',
      lastDocId: isLast ? null : newCursor,
      ...newTotals,
      lastHeartbeatAt: nowIso,
      completedAt: isLast ? nowIso : admin.firestore.FieldValue.delete(),
    }, { merge: true });
  } catch (_) {}

  return { pageScanned: scanned, pageUpdated: updated, pageSkippedEmpty: skippedEmpty, pageAmbiguous: ambiguous, done: isLast, cursor: isLast ? null : newCursor, ...newTotals };
}

exports.runFixCityFromAddressOnce = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
    const db = admin.firestore();
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
    }
    const callerUid = context.auth.uid;
    const adminUid = await getAdminUid(db);
    if (!adminUid || callerUid !== adminUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only the owner can run this');
    }
    const pageSize = Math.max(200, Math.min(1500, Number(data && data.pageSize) || 1200));
    const resume = (data && data.resume) !== false; // default true
    try {
      const res = await runFixCityFromAddressBatch(db, { pageSize, resume });
      return { ok: true, ...res };
    } catch (e) {
      throw new functions.https.HttpsError('internal', e?.message || 'Unknown error');
    }
  });

// HTTP wrapper for CI/admin (shared secret header like others)
exports.runFixCityFromAddressOnceHttp = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method Not Allowed' }); return; }
      const secretConfigured = getEnv('BACKFILL_RUN_SECRET', getEnv('backfill.run_secret', ''));
      const provided = String(req.headers['x-run-secret'] || req.headers['x-runner-secret'] || '').trim();
      if (!secretConfigured || !provided || provided !== secretConfigured) { res.status(401).json({ ok: false, error: 'Unauthorized' }); return; }
      const db = admin.firestore();
      const pageSize = Math.max(200, Math.min(1500, Number((req.body && req.body.pageSize) || 1200)));
      const resume = (req.body && req.body.resume) !== false;
      const out = await runFixCityFromAddressBatch(db, { pageSize, resume });
      res.status(200).json({ ok: true, ...out });
    } catch (e) {
      res.status(500).json({ ok: false, error: e?.message || 'Unhandled error' });
    }
  });

/**
 * Owner-callable: Sweep Fix City/State across all parks in one session (looped)
 * - Loops runFixCityFromAddressBatch() until done or nearing timeout
 * - Returns cumulative totals and done flag
 */
exports.runFixCityFromAddressAll = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
    const db = admin.firestore();
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
    }
    const callerUid = context.auth.uid;
    const adminUid = await getAdminUid(db);
    if (!adminUid || callerUid !== adminUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only the owner can run this');
    }
    let pageSize = Math.max(200, Math.min(1500, Number(data && data.pageSize) || 1200));
    let resume = (data && data.resume) !== false;
    const t0 = Date.now();
    let agg = { pages: 0, scanned: 0, updated: 0, skippedEmpty: 0, ambiguous: 0 };
    let done = false;
    do {
      const out = await runFixCityFromAddressBatch(db, { pageSize, resume });
      // The batch already updates checkpoint totals; also compute local aggregate
      agg.pages = out.pages;
      agg.scanned = out.scanned;
      agg.updated = out.updated;
      agg.skippedEmpty = out.skippedEmpty;
      agg.ambiguous = out.ambiguous;
      done = !!out.done;
      resume = true; // continue from checkpoint
      // Leave ~20s headroom to avoid hard timeout
      if (!done && (Date.now() - t0) > 520000) break;
    } while (!done);
    return { ok: true, ...agg, done };
  });

/**
 * HTTP: Sweep Fix City/State fully with shared secret, no terminal loops needed
 */
exports.runFixCityFromAddressAllHttp = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method Not Allowed' }); return; }
      const secretConfigured = getEnv('BACKFILL_RUN_SECRET', getEnv('backfill.run_secret', ''));
      const provided = String(req.headers['x-run-secret'] || req.headers['x-runner-secret'] || '').trim();
      if (!secretConfigured || !provided || provided !== secretConfigured) { res.status(401).json({ ok: false, error: 'Unauthorized' }); return; }
      const db = admin.firestore();
      let pageSize = Math.max(200, Math.min(1500, Number((req.body && req.body.pageSize) || 1200)));
      let resume = (req.body && req.body.resume) !== false;
      const t0 = Date.now();
      let agg = { pages: 0, scanned: 0, updated: 0, skippedEmpty: 0, ambiguous: 0 };
      let done = false;
      do {
        const out = await runFixCityFromAddressBatch(db, { pageSize, resume });
        agg.pages = out.pages;
        agg.scanned = out.scanned;
        agg.updated = out.updated;
        agg.skippedEmpty = out.skippedEmpty;
        agg.ambiguous = out.ambiguous;
        done = !!out.done;
        resume = true;
        if (!done && (Date.now() - t0) > 520000) break;
      } while (!done);
      res.status(200).json({ ok: true, ...agg, done });
    } catch (e) {
      res.status(500).json({ ok: false, error: e?.message || 'Unhandled error' });
    }
  });

// Removed: runPlacesBackfillForCityHttp (Google import) per request — no more Google importing

// Removed: geocoding queue, scheduler, and HTTP drainer — no reverse‑geocoding API calls

// Removed: enqueueGeocodeOnParkCreate and helper — no auto geocode queueing

// Queue on relevant park updates — DISABLED to avoid potential update loops and costs
// exports.enqueueGeocodeOnParkUpdate = functions.firestore
//   .document('parks/{parkId}')
//   .onUpdate(async (change, context) => {
//     const db = admin.firestore();
//     const before = change.before.data() || {};
//     const after = change.after.data() || {};
//     const bLat = Number(before.latitude);
//     const bLng = Number(before.longitude);
//     const aLat = Number(after.latitude);
//     const aLng = Number(after.longitude);
//     const coordsChanged = (isFinite(aLat) && isFinite(aLng)) && (aLat !== bLat || aLng !== bLng);
//     const missingAddr = !after.address || !after.city || !after.state || String(after.address).trim().toLowerCase() === 'address not specified';
//     const flagged = after.needsGeocode === true;
//     if (!coordsChanged && !missingAddr && !flagged) return null;
//     if (!isFinite(aLat) || !isFinite(aLng)) return null;
//     const reason = coordsChanged ? 'park:update:coords' : (flagged ? 'park:update:flag' : 'park:update:missing');
//     await enqueueGeocodeJob(db, { parkId: change.after.id, lat: aLat, lng: aLng, reason, priority: coordsChanged ? 2 : 5 });
//     return null;
//   });

// On update: refresh alias index when name/coords/approval change
exports.indexParkAliasesOnUpdate = functions.firestore
  .document('parks/{parkId}')
  .onUpdate(async (change, context) => {
    const db = admin.firestore();
    try {
      const after = change.after.data() || {};
      await indexAliasesForPark(db, change.after.id, after);
    } catch (e) {
      console.warn('indexParkAliasesOnUpdate error', e && e.message ? e.message : e);
    }
    return null;
  });

/**
 * Callable: Claim importer ownership (sets config/app.adminUid) on first run.
 * - If adminUid is not set, the first authenticated caller becomes the owner.
 * - If adminUid is set, only the current owner can change it to a new UID
 *   by passing { newOwnerUid }.
 */
exports.claimImporterOwner = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
  }
  const db = admin.firestore();
  const callerUid = context.auth.uid;

  try {
    const ref = db.collection('config').doc('app');
    const snap = await ref.get();
    const doc = snap.exists ? snap.data() : {};
    const current = doc && doc.adminUid ? String(doc.adminUid) : '';

    // If no owner configured yet, let the first authenticated caller claim it
    if (!current) {
      await ref.set({ adminUid: callerUid, updatedAt: new Date().toISOString() }, { merge: true });
      // also mark the user as admin; a separate trigger keeps it consistent later
      await db.collection('users').doc(callerUid).set({ isAdmin: true, updatedAt: new Date().toISOString() }, { merge: true });
      // warm the cache
      cachedAdminUid = callerUid; cachedAt = Date.now();
      return { ok: true, owner: callerUid, claimed: true };
    }

    // Owner is already set; only the existing owner can reassign
    if (callerUid !== current) {
      throw new functions.https.HttpsError('permission-denied', 'Only the current owner can change ownership');
    }

    const newOwnerUid = data && data.newOwnerUid ? String(data.newOwnerUid) : '';
    if (!newOwnerUid) {
      // No change requested, just return current status
      return { ok: true, owner: current, claimed: false };
    }
    if (newOwnerUid === current) {
      return { ok: true, owner: current, claimed: false };
    }

    await ref.set({ adminUid: newOwnerUid, updatedAt: new Date().toISOString() }, { merge: true });
    // ensure flags reflect the new owner
    await db.collection('users').doc(current).set({ isAdmin: false, updatedAt: new Date().toISOString() }, { merge: true }).catch(() => {});
    await db.collection('users').doc(newOwnerUid).set({ isAdmin: true, updatedAt: new Date().toISOString() }, { merge: true }).catch(() => {});
    cachedAdminUid = newOwnerUid; cachedAt = Date.now();
    return { ok: true, owner: newOwnerUid, reassigned: true };
  } catch (e) {
    const msg = (e && e.message) ? e.message : String(e);
    console.error('claimImporterOwner error', msg);
    if (e instanceof functions.https.HttpsError) throw e;
    throw new functions.https.HttpsError('internal', msg || 'Unknown error');
  }
});

/**
 * ========================
 * GEO GATEWAY (onCall)
 * ========================
 * Provides server-side endpoints for text search, place details, and reverse geocoding
 * with Firestore caching, a low-cost fallback provider (Geoapify), and Google as
 * secondary. Keys are read from environment variables or functions config.
 *
 * Compliance guardrails:
 * - Only minimal fields are cached (name, address, lat/lng, provider)
 * - TTL enforced via expiresAt; expired entries are not returned
 * - No long-term caching of Google proprietary fields beyond minimal essentials
 */

const crypto = require('crypto');
const https = require('https');
const { URL } = require('url');
const zlib = require('zlib');

/**
 * Minimal HTTPS helper to avoid relying on global fetch in Node runtimes.
 * Returns { ok, status, json(), text() }
 */
function httpRequest(method, urlString, { headers = {}, body = null, timeoutMs = 0 } = {}) {
  return new Promise((resolve) => {
    try {
      const url = new URL(urlString);
      const options = {
        method,
        hostname: url.hostname,
        path: url.pathname + (url.search || ''),
        port: url.port || (url.protocol === 'https:' ? 443 : 80),
        headers,
      };

      const req = https.request(options, (res) => {
        const chunks = [];
        res.on('data', (d) => chunks.push(d));
        res.on('end', () => {
          const buffer = Buffer.concat(chunks);
          const enc = (res.headers && (res.headers['content-encoding'] || res.headers['Content-Encoding'])) || '';
          const finish = (buf) => {
            const text = buf.toString('utf8');
            const makeResp = (ok) => ({
              ok,
              status: res.statusCode || 0,
              async json() {
                try { return JSON.parse(text); } catch (_) { return {}; }
              },
              async text() { return text; },
            });
            resolve(makeResp(res.statusCode && res.statusCode >= 200 && res.statusCode < 300));
          };
          if (enc.includes('gzip')) {
            zlib.gunzip(buffer, (err, out) => finish(err ? buffer : out));
          } else if (enc.includes('deflate')) {
            zlib.inflate(buffer, (err, out) => finish(err ? buffer : out));
          } else {
            finish(buffer);
          }
        });
      });
      req.on('error', () => resolve({ ok: false, status: 0, json: async () => ({}), text: async () => '' }));
      if (timeoutMs && timeoutMs > 0) {
        req.setTimeout(timeoutMs, () => {
          try { req.destroy(new Error('Request timeout')); } catch (_) {}
          resolve({ ok: false, status: 0, json: async () => ({}), text: async () => 'Request timeout' });
        });
      }
      if (body) {
        if (typeof body === 'string' || Buffer.isBuffer(body)) {
          req.write(body);
        } else {
          const str = JSON.stringify(body);
          req.write(str);
        }
      }
      req.end();
    } catch (_) {
      resolve({ ok: false, status: 0, json: async () => ({}), text: async () => '' });
    }
  });
}

function getEnv(keyPath, fallback = '') {
  // Try process.env first, then functions config (e.g., functions.config().maps.google_server_key)
  if (process.env[keyPath]) return process.env[keyPath];
  try {
    const parts = keyPath.split('.');
    let cfg = functions.config();
    for (const p of parts) {
      if (!cfg || typeof cfg !== 'object') return fallback;
      cfg = cfg[p];
    }
    return (typeof cfg === 'string' && cfg) ? cfg : fallback;
  } catch (_) {
    return fallback;
  }
}

/**
 * Nightly window helper: returns true if the current UTC hour is within the
 * configured import window. Defaults to 06:00–12:00 UTC (overnight in US timezones).
 *
 * Configure via Firestore doc config/app.importWindowUtc = { startHour: 6, endHour: 12 }
 * - startHour/endHour are integers 0..23
 * - If startHour < endHour: window is [startHour, endHour)
 * - If startHour > endHour: window wraps midnight (e.g., 22..02)
 * - If missing/invalid: defaults are applied
 */
async function isWithinNightlyWindowUtc(db) {
  const nowHour = new Date().getUTCHours();
  let start = 6, end = 12; // default window: 06:00–12:00 UTC
  try {
    const snap = await db.collection('config').doc('app').get();
    const cfg = snap.exists ? snap.data() : {};
    const w = cfg && cfg.importWindowUtc;
    const s = Number(w && w.startHour);
    const e = Number(w && w.endHour);
    if (isFinite(s) && s >= 0 && s <= 23) start = s;
    if (isFinite(e) && e >= 0 && e <= 23) end = e;
  } catch (_) {}
  if (start === end) return true; // degenerate => always allowed
  if (start < end) return nowHour >= start && nowHour < end;
  // wrap midnight
  return nowHour >= start || nowHour < end;
}

// Keys can be provided via:
// - process.env.GOOGLE_MAPS_SERVER_KEY
// - functions config: maps.google_server_key
const GOOGLE_KEY = getEnv('GOOGLE_MAPS_SERVER_KEY', getEnv('maps.google_server_key'));
// Global switch: no fallbacks. Google is the only provider now.
const FORCE_DISABLE_GOOGLE_FALLBACK = false;

const GEO_CACHE_COLL = 'geoCache';
// Monthly call stop-cap for Google Places/Geocode (all Google API calls)
// Env/config override: GOOGLE_PLACES_MONTHLY_CAP or places.monthly_cap
const GOOGLE_MONTHLY_CAP_DEFAULT = 90000; // hard stop at 90,000 calls/month by default

function currentMonthKey() {
  const d = new Date();
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  return `${y}-${m}`;
}

function getGoogleMonthlyCap() {
  const raw = getEnv('GOOGLE_PLACES_MONTHLY_CAP', getEnv('places.monthly_cap', String(GOOGLE_MONTHLY_CAP_DEFAULT)));
  const n = Number(raw);
  if (!isFinite(n) || n < 0) return GOOGLE_MONTHLY_CAP_DEFAULT;
  return Math.max(0, Math.floor(n));
}

async function getGoogleRemainingCalls(db) {
  try {
    const month = currentMonthKey();
    const ref = db.collection('billing').doc('usage').collection('google').doc(month);
    const snap = await ref.get();
    const used = snap.exists ? Number(snap.data().placesCalls || 0) : 0;
    const cap = getGoogleMonthlyCap();
    return Math.max(0, cap - used);
  } catch (_) {
    return 0;
  }
}

async function consumeGoogleCalls(db, calls) {
  try {
    const month = currentMonthKey();
    const ref = db.collection('billing').doc('usage').collection('google').doc(month);
    await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const prevCalls = snap.exists ? Number(snap.data().placesCalls || 0) : 0;
      tx.set(ref, {
        month,
        placesCalls: prevCalls + calls,
        updatedAt: new Date().toISOString(),
      }, { merge: true });
    });
  } catch (e) {
    console.warn('consumeGoogleCalls failed', e);
  }
}
const TEXT_TTL_DAYS = 14; // cache text search for 14 days
const REV_TTL_DAYS = 30;  // cache reverse geocode for 30 days
const DETAILS_TTL_DAYS = 30; // cache place details for 30 days (compliance)

function ttlFromDays(days) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString();
}

function isExpired(doc) {
  const exp = doc && doc.expiresAt ? new Date(doc.expiresAt) : null;
  if (!exp) return true;
  return new Date() > exp;
}

function normalizeQueryKey(obj) {
  const json = JSON.stringify(obj, Object.keys(obj).sort());
  return crypto.createHash('sha256').update(json).digest('hex');
}

async function cacheGet(db, key) {
  try {
    const ref = db.collection(GEO_CACHE_COLL).doc(key);
    const snap = await ref.get();
    if (!snap.exists) return null;
    const data = snap.data();
    if (isExpired(data)) return null;
    return data.payload || null;
  } catch (e) {
    console.warn('cacheGet error', e);
    return null;
  }
}

async function cacheSet(db, key, payload, ttlDays) {
  try {
    const ref = db.collection(GEO_CACHE_COLL).doc(key);
    const now = new Date().toISOString();
    await ref.set({
      payload,
      createdAt: now,
      expiresAt: ttlFromDays(ttlDays),
    }, { merge: true });
  } catch (e) {
    console.warn('cacheSet error', e);
  }
}

// Geoapify has been removed from the pipeline. Google-only below.

function standardizePlacesFromGoogleV1(resp) {
  const places = Array.isArray(resp.places) ? resp.places : [];
  return places.map(p => {
    const loc = p.location || {};
    const name = (p.displayName && p.displayName.text) || p.displayName || 'Unknown';
    return {
      id: p.id || `${name}_${loc.latitude},${loc.longitude}`,
      displayName: name,
      formattedAddress: p.formattedAddress || '',
      location: { latitude: loc.latitude, longitude: loc.longitude },
      provider: 'google'
    };
  });
}

// Geoapify text search removed

async function fetchGoogleTextSearch(text, bias) {
  if (!GOOGLE_KEY) return [];
  const url = 'https://places.googleapis.com/v1/places:searchText';
  const body = { textQuery: text };
  if (bias && typeof bias.lat === 'number' && typeof bias.lng === 'number' && typeof bias.radius === 'number') {
    body.locationBias = { circle: { center: { latitude: bias.lat, longitude: bias.lng }, radius: bias.radius } };
    body.rankPreference = 'DISTANCE';
  }
  const res = await httpRequest('POST', url, {
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
      'X-Goog-Api-Key': GOOGLE_KEY,
      'X-Goog-FieldMask': 'places.id,places.displayName,places.formattedAddress,places.location'
    },
    body: JSON.stringify(body)
  });
  if (!res.ok) return [];
  const data = await res.json();
  const raw = standardizePlacesFromGoogleV1(data);
  // Attach alias hint (best-effort) so clients can link to canonical parks
  try {
    return await attachAliasesToPlaces(admin.firestore(), raw);
  } catch (_) {
    return raw;
  }
}

async function fetchGoogleTextSearchPaged({ text, bias, pageAll = true, maxPages = 3, pageSize = 20 }) {
  if (!GOOGLE_KEY) return { places: [], nextPageToken: null };
  const url = 'https://places.googleapis.com/v1/places:searchText';
  let nextPageToken = null;
  let pagesFetched = 0;
  const aggregated = new Map();

  function fieldMask(includeNextToken) {
    const base = 'places.id,places.displayName,places.formattedAddress,places.location';
    return includeNextToken ? `nextPageToken,${base}` : base;
  }

  const baseBody = { textQuery: text, pageSize };
  if (bias && typeof bias.lat === 'number' && typeof bias.lng === 'number' && typeof bias.radius === 'number') {
    baseBody.locationBias = { circle: { center: { latitude: bias.lat, longitude: bias.lng }, radius: bias.radius } };
    // Avoid rankPreference to reduce INVALID_ARGUMENT in some accounts; keep default relevance order
  }

  do {
    const body = nextPageToken ? { ...baseBody, pageToken: nextPageToken } : baseBody;
    const mask = fieldMask(true);
    const res = await httpRequest('POST', url, {
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Goog-Api-Key': GOOGLE_KEY,
        'X-Goog-FieldMask': mask
      },
      body: JSON.stringify(body)
    });
    if (!res.ok) break;
    const data = await res.json();
    let places = standardizePlacesFromGoogleV1(data);
    try {
      places = await attachAliasesToPlaces(admin.firestore(), places);
    } catch (_) {}
    for (const p of places) {
      const id = p.id || `${p.displayName}_${(p.location?.latitude ?? 0)},${(p.location?.longitude ?? 0)}`;
      aggregated.set(id, p);
    }
    nextPageToken = data.nextPageToken || null;
    pagesFetched += 1;
    if (!pageAll || !nextPageToken || pagesFetched >= maxPages) break;
    // Pagination token readiness backoff
    await new Promise(r => setTimeout(r, pagesFetched === 1 ? 1500 : 2000));
  } while (true);

  return { places: Array.from(aggregated.values()), nextPageToken };
}

exports.geoTextSearch = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  try {
    const text = (data && data.text ? String(data.text) : '').trim();
    const bias = data && data.bias ? {
      lat: Number(data.bias.lat),
      lng: Number(data.bias.lng),
      radius: data.bias.radius ? Number(data.bias.radius) : undefined
    } : null;
    if (!text || text.length < 3) {
      return { places: [] };
    }

    // Cache key is based on text + bias
    const key = 'text:' + normalizeQueryKey({ text, bias });
    const cached = await cacheGet(db, key);
    if (cached && Array.isArray(cached.places)) {
      return cached;
    }

    // Google-only search with monthly cap
    const remaining = await getGoogleRemainingCalls(db);
    if (remaining <= 0) return { places: [] };
    let places = [];
    try {
      places = await fetchGoogleTextSearch(text, bias);
      await consumeGoogleCalls(db, 1);
    } catch (e) { console.warn('Google text search error', e); }

    const payload = { places };
    await cacheSet(db, key, payload, TEXT_TTL_DAYS);
    return payload;
  } catch (e) {
    // Fail soft: return empty results instead of throwing, so clients can fallback gracefully
    console.error('geoTextSearch error (soft-fail)', e);
    return { places: [] };
  }
});

// Versioned server-first text search with optional pagination and aggregation
exports.geoTextSearchV2 = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  try {
    const text = (data && data.text ? String(data.text) : '').trim();
    const pageAll = !!(data && data.pageAll);
    // Allow slightly deeper coverage for large cities while guarding cost. Cap at 6.
    const maxPages = Math.max(1, Math.min(6, Number(data && data.maxPages) || 3));
    const pageSize = Math.max(10, Math.min(20, Number(data && data.pageSize) || 20));
    const bias = data && data.bias ? {
      lat: Number(data.bias.lat),
      lng: Number(data.bias.lng),
      radius: data.bias.radius ? Number(data.bias.radius) : undefined
    } : null;
    if (!text || text.length < 3) {
      return { places: [] };
    }

    const key = 'textv2:' + normalizeQueryKey({ text, pageAll, maxPages, pageSize, bias });
    const cached = await cacheGet(db, key);
    if (cached && Array.isArray(cached.places)) {
      return cached;
    }

    // Google-only paged search with monthly cap
    let remaining = await getGoogleRemainingCalls(db);
    if (remaining <= 0) return { places: [] };
    const allowedPages = Math.max(1, Math.min(maxPages, remaining));
    let places = [];
    try {
      const out = await fetchGoogleTextSearchPaged({ text, bias, pageAll, maxPages: allowedPages, pageSize });
      places = out.places || [];
      const pagesUsed = Math.min(allowedPages, Math.ceil((places.length || 1) / pageSize));
      await consumeGoogleCalls(db, pagesUsed);
    } catch (e) { console.warn('Google text search v2 error', e); }

    const payload = { places };
    await cacheSet(db, key, payload, TEXT_TTL_DAYS);
    return payload;
  } catch (e) {
    console.error('geoTextSearchV2 error (soft-fail)', e);
    return { places: [] };
  }
});

/**
 * Scheduled Function: prune expired geo cache docs
 */
exports.pruneExpiredGeoCache = functions.pubsub
  .schedule('every 24 hours')
  .timeZone('Etc/UTC')
  .onRun(async (context) => {
    const db = admin.firestore();
    try {
      const nowIso = new Date().toISOString();
      const snap = await db.collection(GEO_CACHE_COLL).where('expiresAt', '<', nowIso).get();
      if (snap.empty) {
        console.log('No expired geo cache docs');
        return null;
      }
      const batch = db.batch();
      snap.forEach(doc => batch.delete(doc.ref));
      await batch.commit();
      console.log(`Pruned ${snap.size} expired geo cache docs.`);
      return null;
    } catch (e) {
      console.error('Error pruning geo cache', e);
      return null;
    }
  });

/**
 * Scheduled Function: Unapprove expired Google-sourced parks
 * Any park with source=='places' and autoExpireAt < now will be hidden (approved=false)
 * unless it has been claimed by a user (createdByUserId not 'system').
 */
exports.pruneExpiredGoogleParks = functions.pubsub
  .schedule('every 24 hours')
  .timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const nowIso = new Date().toISOString();
    try {
      const snap = await db.collection('parks')
        .where('source', '==', 'places')
        .where('autoExpireAt', '<', nowIso)
        .get();
      if (snap.empty) return null;
      const updates = [];
      snap.forEach(doc => {
        const d = doc.data() || {};
        const creator = String(d.createdByUserId || '');
        // Preserve user-created/claimed entries
        if (creator && creator !== 'system') return;
        updates.push(doc.ref.set({ approved: false, reviewStatus: 'expired_cache', expiredAt: nowIso, updatedAt: nowIso }, { merge: true }));
      });
      if (updates.length) await Promise.all(updates);
      console.log(`Expired Google parks pruned: ${updates.length}`);
      return null;
    } catch (e) {
      console.warn('pruneExpiredGoogleParks error', e && e.message ? e.message : e);
      return null;
    }
  });

// OSM callable removed — Google-only pipeline

// Geoapify reverse removed

async function fetchGoogleReverse(lat, lng) {
  if (!GOOGLE_KEY) return null;
  const url = `https://maps.googleapis.com/maps/api/geocode/json?latlng=${lat},${lng}&key=${GOOGLE_KEY}`;
  const res = await httpRequest('GET', url);
  if (!res.ok) return null;
  const data = await res.json();
  const results = Array.isArray(data.results) ? data.results : [];
  if (!results.length) return null;
  const first = results[0];
  const comps = Array.isArray(first.address_components) ? first.address_components : [];
  let streetNumber, route, city, stateShort;
  for (const c of comps) {
    const types = c.types || [];
    if (types.includes('street_number')) streetNumber = c.long_name;
    if (types.includes('route')) route = c.long_name;
    if (types.includes('locality')) city = c.long_name;
    if (types.includes('administrative_area_level_1')) stateShort = c.short_name;
    if (!city && (types.includes('postal_town') || types.includes('sublocality') || types.includes('neighborhood'))) {
      city = c.long_name;
    }
  }
  const address = [streetNumber, route].filter(Boolean).join(' ');
  return { address: address || first.formatted_address || '', city: city || '', state: stateShort || '' };
}

exports.geoReverseGeocode = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  try {
    const lat = Number(data && data.lat);
    const lng = Number(data && data.lng);
    if (!isFinite(lat) || !isFinite(lng)) {
      throw new functions.https.HttpsError('invalid-argument', 'lat and lng are required');
    }

    const key = 'rev:' + normalizeQueryKey({ lat: Math.round(lat * 1e5) / 1e5, lng: Math.round(lng * 1e5) / 1e5 });
    const cached = await cacheGet(db, key);
    if (cached) return cached;

    let result = null;
    const remaining = await getGoogleRemainingCalls(db);
    if (remaining > 0) {
      try { result = await fetchGoogleReverse(lat, lng); await consumeGoogleCalls(db, 1); } catch (e) { console.warn('Google reverse error', e); }
    }
    const payload = result || { address: '', city: '', state: '' };
    await cacheSet(db, key, payload, REV_TTL_DAYS);
    return payload;
  } catch (e) {
    // Fail soft
    console.error('geoReverseGeocode error (soft-fail)', e);
    return { address: '', city: '', state: '' };
  }
});

async function fetchGooglePlaceDetails(placeId) {
  if (!GOOGLE_KEY) return null;
  // Places API v1: GET place details
  // Documentation: https://developers.google.com/maps/documentation/places/web-service/details#http
  // Note: placeId here should be the v1 "id" (e.g., returned by v1 search) or a legacy ID that also works with v1.
  const url = `https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}`;
  const res = await httpRequest('GET', url, {
    headers: {
      'X-Goog-Api-Key': GOOGLE_KEY,
      'X-Goog-FieldMask': 'id,displayName,formattedAddress,location'
    }
  });
  if (!res.ok) {
    // Include minimal info for easier debugging while avoiding leaking keys
    const text = await res.text().catch(() => '');
    console.warn('Places v1 details non-OK response', res.status, text);
    return null;
  }
  const p = await res.json();
  const loc = p.location || {};
  const name = (p.displayName && p.displayName.text) || p.displayName || 'Unknown';
  return {
    id: p.id || placeId,
    displayName: name,
    formattedAddress: p.formattedAddress || '',
    location: (typeof loc.latitude === 'number' && typeof loc.longitude === 'number')
      ? { latitude: loc.latitude, longitude: loc.longitude }
      : null,
    provider: 'google'
  };
}

exports.geoPlaceDetails = functions.https.onCall(async (data, context) => {
  const db = admin.firestore();
  try {
    const placeId = (data && data.placeId ? String(data.placeId) : '').trim();
    if (!placeId) throw new functions.https.HttpsError('invalid-argument', 'placeId is required');
    const key = 'det:' + normalizeQueryKey({ placeId });
    const cached = await cacheGet(db, key);
    if (cached) return cached;
    let details = null;
    const remaining = await getGoogleRemainingCalls(db);
    if (remaining > 0) {
      details = await fetchGooglePlaceDetails(placeId);
      await consumeGoogleCalls(db, 1);
    }
    if (!details) {
      // Soft-fail: return a minimal stub so client can proceed without error
      return { id: placeId, displayName: 'Unknown', formattedAddress: '', location: null, provider: 'google' };
    }
    // Attach alias link for details (best-effort)
    try {
      const dn = String(details.displayName || '');
      const loc = details.location || {};
      const la = Number(loc.latitude);
      const lo = Number(loc.longitude);
      if (dn && isFinite(la) && isFinite(lo)) {
        const key3 = clusterKey(la, lo, 3);
        for (const v of aliasVariantsFromName(dn)) {
          const aid = `a:${v}:${key3}`;
          const snap = await db.collection('parkAliases').doc(aid).get();
          if (snap.exists) {
            const target = snap.data() || {};
            if (target.parkId) {
              details = { ...details, aliasParkId: target.parkId, aliasMatch: true };
              break;
            }
          }
        }
      }
    } catch (_) {}
    await cacheSet(db, key, details, DETAILS_TTL_DAYS);
    return details;
  } catch (e) {
    // Fail soft
    console.error('geoPlaceDetails error (soft-fail)', e);
    return { id: '', displayName: 'Unknown', formattedAddress: '', location: null, provider: 'google' };
  }
});

/**
 * ========================
 * PARKS BACKFILL (metadata cleanup)
 * ========================
 * This section retains the non-provider-specific backfill used to normalize existing
 * parks (names/addresses). Geoapify dependencies were removed. No external calls here.
 */

function isMissingAddress(s) {
  if (!s) return true;
  const t = String(s).trim();
  if (!t) return true;
  return t.toLowerCase() === 'address not specified';
}

function isMissingOrGenericName(s) {
  const t = (s || '').trim();
  if (!t) return true;
  const low = t.toLowerCase();
  if (low === 'unknown park') return true;
  if (/^(basketball|tennis|pickleball) court(s)?$/i.test(low)) return true;
  if (/^(court|courts)\s*\d*$/i.test(low)) return true;
  return false;
}

function isTwoLetterState(s) { return /^[A-Za-z]{2}$/.test(s || ''); }

const NAME_TO_CODE = {
  'alabama': 'AL','alaska': 'AK','arizona': 'AZ','arkansas': 'AR','california': 'CA','colorado': 'CO','connecticut': 'CT','delaware': 'DE','florida': 'FL','georgia': 'GA','hawaii': 'HI','idaho': 'ID','illinois': 'IL','indiana': 'IN','iowa': 'IA','kansas': 'KS','kentucky': 'KY','louisiana': 'LA','maine': 'ME','maryland': 'MD','massachusetts': 'MA','michigan': 'MI','minnesota': 'MN','mississippi': 'MS','missouri': 'MO','montana': 'MT','nebraska': 'NE','nevada': 'NV','new hampshire': 'NH','new jersey': 'NJ','new mexico': 'NM','new york': 'NY','north carolina': 'NC','north dakota': 'ND','ohio': 'OH','oklahoma': 'OK','oregon': 'OR','pennsylvania': 'PA','rhode island': 'RI','south carolina': 'SC','south dakota': 'SD','tennessee': 'TN','texas': 'TX','utah': 'UT','vermont': 'VT','virginia': 'VA','washington': 'WA','west virginia': 'WV','wisconsin': 'WI','wyoming': 'WY','district of columbia': 'DC','dc': 'DC'
};

function canonState(state) {
  const s = String(state || '').trim();
  if (!s) return s;
  if (isTwoLetterState(s)) return s.toUpperCase();
  return NAME_TO_CODE[s.toLowerCase()] || s.toUpperCase();
}

function streetFromAddress(address) {
  const a = String(address || '');
  if (!a.trim()) return '';
  const firstComma = a.indexOf(',');
  if (firstComma === -1) return a.trim();
  return a.substring(0, firstComma).trim();
}

function looksNumericStreet(street) {
  const s = String(street || '');
  if (!s) return false;
  return /^\d{3,6}\s/i.test(s);
}

function sportPluralLabel(sport) {
  switch (sport) {
    case 'basketball': return 'Basketball Courts';
    case 'tennisSingles':
    case 'tennisDoubles': return 'Tennis Courts';
    case 'pickleballSingles':
    case 'pickleballDoubles': return 'Pickleball Courts';
    default: return 'Basketball Courts';
  }
}

function fallbackNameFromContext({ original, address, city, sport }) {
  const label = sportPluralLabel(sport || 'basketball');
  const street = streetFromAddress(address);
  if (street && !looksNumericStreet(street)) return `${street} — ${label}`;
  if ((city || '').trim()) return `${String(city).trim()} — ${label}`;
  return label;
}

function parseCityStateFromAddress(address) {
  const parts = String(address || '')
    .split(',')
    .map((s) => s.trim())
    .filter((s) => !!s);

  let city = '';
  let state = '';

  // Helper: should we ignore this token as a city candidate?
  const isBadCityToken = (seg) => {
    const s = String(seg || '').trim();
    if (!s) return true;
    const low = s.toLowerCase();
    if (low === 'usa' || low === 'united states') return true;
    if (low.endsWith(' county')) return true;
    // ZIP or ZIP+4 or tokens like "CA 94501"
    if (/^\d{5}(-\d{4})?$/.test(s)) return true;
    if (/^[A-Za-z]{2}\s*\d{5}(-\d{4})?$/.test(s)) return true;
    return false;
  };

  // 1) Try to locate a 2-letter state token; otherwise fall back to full name
  let stateIndex = -1;
  for (let i = 0; i < parts.length; i++) {
    const m = parts[i].match(/\b([A-Za-z]{2})\b/);
    if (m && isTwoLetterState(m[1])) {
      state = m[1].toUpperCase();
      stateIndex = i;
      break;
    }
  }
  if (!state) {
    for (let i = 0; i < parts.length; i++) {
      const code = NAME_TO_CODE[parts[i].toLowerCase()];
      if (code) {
        state = code;
        stateIndex = i;
        break;
      }
    }
  }

  // 2) Choose the nearest good token before the state as the city
  if (stateIndex > 0) {
    for (let j = stateIndex - 1; j >= 0; j--) {
      if (!isBadCityToken(parts[j])) { city = parts[j]; break; }
    }
  }

  // Final cleanup: title case city-like tokens such as "oakland" -> "Oakland"
  return { city: (city || '').trim(), state: canonState(state) };
}

function titleCase(input) {
  const s = String(input || '');
  if (!s.trim()) return s;
  const words = s.toLowerCase().split(/\s+/);
  const capped = words.map((w) => (w ? w[0].toUpperCase() + (w.length > 1 ? w.substring(1) : '') : w));
  const small = new Set(['Of','And','The','At','In','On','For','To']);
  for (let i = 1; i < capped.length - 1; i++) { if (small.has(capped[i])) capped[i] = capped[i].toLowerCase(); }
  return capped.join(' ');
}

function clusterKey(lat, lng, decimals = 3) {
  const r = (v) => Number(v).toFixed(decimals);
  return `${r(lat)},${r(lng)}`;
}

/**
 * ========================
 * ALIAS LINKING (in-flight, small)
 * ========================
 * We create tiny alias indices for approved parks so that when Google Places
 * returns slightly different names (e.g., "Rose Garden" vs "Rose Park"),
 * we can link results to an existing canonical park to avoid duplicates.
 *
 * Collection: parkAliases
 *   DocID: a:<aliasNameNorm>:<clusterKey_3dec>
 *   Fields: { parkId, name, alias, lat, lon, createdAt, updatedAt }
 */
function normalizeAliasName(name) {
  const s = String(name || '').toLowerCase();
  return s
    .replace(/[\u2014\u2013]/g, '-')
    .replace(/[^a-z0-9\s-]/g, ' ')
    .replace(/\b(basketball|tennis|pickleball|courts?|recreation|rec|center|complex|playground|ymca|school|university|college)\b/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function aliasVariantsFromName(name) {
  // Keep aliasing extremely conservative: only the normalized base name.
  // No garden/park swaps or broad synonyms.
  const base = normalizeAliasName(name);
  return base ? [base] : [];
}

async function indexAliasesForPark(db, parkId, data) {
  try {
    if (!data || !data.approved) return; // only approved parks participate
    const name = data.name || '';
    const lat = Number(data.latitude);
    const lon = Number(data.longitude);
    if (!name || !isFinite(lat) || !isFinite(lon)) return;
    const key3 = clusterKey(lat, lon, 3);
    const variants = aliasVariantsFromName(name);
    const nowIso = new Date().toISOString();
    const writes = variants.slice(0, 6).map(v => {
      const aliasId = `a:${v}:${key3}`;
      return db.collection('parkAliases').doc(aliasId).set({
        parkId: parkId,
        name: String(name),
        alias: v,
        lat,
        lon,
        updatedAt: nowIso,
        createdAt: data.createdAt || nowIso,
      }, { merge: true });
    });
    await Promise.all(writes);
  } catch (e) {
    console.warn('indexAliasesForPark error', e && e.message ? e.message : e);
  }
}

async function attachAliasesToPlaces(db, places) {
  if (!Array.isArray(places) || places.length === 0) return places || [];
  const ids = new Set();
  for (const p of places.slice(0, 80)) {
    const dn = p.displayName && p.displayName.text ? p.displayName.text : (p.displayName || '');
    const loc = p.location || {};
    const la = Number(loc.latitude);
    const lo = Number(loc.longitude);
    if (!dn || !isFinite(la) || !isFinite(lo)) continue;
    const key3 = clusterKey(la, lo, 3);
    for (const v of aliasVariantsFromName(dn)) {
      ids.add(`a:${v}:${key3}`);
    }
  }
  const lookups = Array.from(ids).map(id => db.collection('parkAliases').doc(id).get().then(s => ({ id, s })).catch(() => null));
  const snaps = await Promise.all(lookups);
  const mapAlias = new Map();
  for (const rec of snaps) {
    if (!rec || !rec.s || !rec.s.exists) continue;
    const d = rec.s.data() || {};
    if (d.parkId) mapAlias.set(rec.id, d.parkId);
  }
  return places.map(p => {
    const dn = p.displayName && p.displayName.text ? p.displayName.text : (p.displayName || '');
    const loc = p.location || {};
    const la = Number(loc.latitude);
    const lo = Number(loc.longitude);
    if (!dn || !isFinite(la) || !isFinite(lo)) return p;
    const key3 = clusterKey(la, lo, 3);
    for (const v of aliasVariantsFromName(dn)) {
      const aid = `a:${v}:${key3}`;
      const parkId = mapAlias.get(aid);
      if (parkId) {
        return { ...p, aliasParkId: parkId, aliasMatch: true };
      }
    }
    return p;
  });
}

async function runParksBackfillBatch({ db, settings, ownerUid, startAfterId = null }) {
  const pageSize = Math.max(200, Math.min(900, Number(settings.pageSize) || 600));
  const mode = settings.mode || 'balanced';
  const capPerRun = Math.max(0, Number(settings.capPerRun) || 50000);
  const clusterDecimals = Math.max(2, Math.min(5, Number(settings.clusterDecimals) || 3));
  const parseCityStateNoApi = settings.parseCityStateNoApi !== false; // default true
  const refineNamesCap = Math.max(0, Number(settings.refineNamesCap) || 0);

  let scanned = 0, updated = 0, noCoords = 0, apiMisses = 0, rgCalls = 0, clustersTouched = 0, pages = 0;
  let refineUsed = 0;
  const t0 = Date.now();
  const placesCacheAddr = new Map(); // key -> { addr, city, state }
  const clusterGoodName = new Map(); // key|sport -> name
  const clusterGeocoded = new Set();
  // External reverse geocode removed from this pass to avoid API burn

  let base = db.collection('parks').orderBy(admin.firestore.FieldPath.documentId());
  if (startAfterId) {
    try {
      const curSnap = await db.collection('parks').doc(startAfterId).get();
      if (curSnap.exists) base = base.startAfter(curSnap);
    } catch (_) {}
  }

  let cursor = null;
  let writesInBatch = 0;
  let batch = db.batch();

  const commitBatch = async () => { if (writesInBatch > 0) { await batch.commit(); batch = db.batch(); writesInBatch = 0; } };

  const pageSnap = await base.limit(pageSize).get();
  if (pageSnap.empty) {
    return { scanned: 0, updated: 0, noCoords: 0, apiMisses: 0, rgCalls: 0, clustersTouched: 0, pages: 0, cursor: null, done: true };
  }

  const docs = pageSnap.docs;
  for (const doc of docs) {
    scanned += 1;
    const data = doc.data() || {};
    const id = doc.id;
    cursor = id;
    const name = String(data.name || '').trim();
    let address = String(data.address || '').trim();
    let city = String(data.city || '').trim();
    let state = String(data.state || '').trim();
    const latitude = Number(data.latitude || 0);
    const longitude = Number(data.longitude || 0);
    const courts = Array.isArray(data.courts) ? data.courts : [];
    const sportType = (courts && courts[0] && courts[0].sportType) || 'basketball';

    const missingName = isMissingOrGenericName(name);
    const missingAddr = isMissingAddress(address) || !city || !state;
    if (!missingName && !missingAddr) continue;
    if (!isFinite(latitude) || !isFinite(longitude) || latitude === 0 || longitude === 0) { noCoords += 1; continue; }

    let newAddress = address;
    let newCity = city;
    let newState = state;
    let newName = name;

    const key = clusterKey(latitude, longitude, clusterDecimals);
    let rg = null;

    if (mode === 'ultraConservative') {
      if (parseCityStateNoApi && (!newCity || !newState) && newAddress.trim()) {
        const parsed = parseCityStateFromAddress(newAddress);
        if (!newCity && parsed.city) newCity = parsed.city;
        if (!newState && parsed.state) newState = parsed.state;
      }
      if (missingName) {
        newName = fallbackNameFromContext({ original: name, address: newAddress, city: newCity, sport: sportType });
      }
    } else if (mode === 'balanced') {
      const known = placesCacheAddr.get(key);
      if (missingAddr && known) {
        if (known.addr) newAddress = newAddress || known.addr;
        if (known.city) newCity = newCity || known.city;
        if (known.state) newState = newState || known.state;
      }
      const spKey = `${key}|${sportType.includes('tennis') ? 'tennis' : sportType.includes('pickle') ? 'pickleball' : 'basketball'}`;
      const knownName = clusterGoodName.get(spKey);
      if (missingName && knownName) newName = knownName;
      // No external reverse calls in balanced mode anymore
      if (!isMissingAddress(address) && city && state) {
        placesCacheAddr.set(key, { addr: address, city, state: canonState(state) });
      }
      if (!isMissingOrGenericName(name)) {
        clusterGoodName.set(spKey, name);
      }
      if (missingName) {
        newName = fallbackNameFromContext({ original: name, address: newAddress, city: newCity, sport: sportType });
      }
    } else { // full
      // Full mode external reverse removed
      if (missingName) {
        newName = fallbackNameFromContext({ original: name, address: newAddress, city: newCity, sport: sportType });
      }
    }

    if (parseCityStateNoApi && (!newCity || !newState) && newAddress.trim()) {
      const parsed = parseCityStateFromAddress(newAddress);
      if (!newCity && parsed.city) newCity = parsed.city;
      if (!newState && parsed.state) newState = parsed.state;
    }

    if (refineNamesCap > 0 && refineUsed < refineNamesCap && isMissingOrGenericName(newName)) {
      // Lightweight server-side name refinement: reuse reverse geocode city to build a better label
      const label = sportPluralLabel(sportType);
      const street = streetFromAddress(newAddress);
      const isNum = looksNumericStreet(street);
      if (street && !isNum) {
        newName = `${street} — ${label}`;
      } else if (newCity) {
        newName = `${newCity} — ${label}`;
      } else {
        newName = label;
      }
      refineUsed += 1;
    }

    const origName = String(data.name || '');
    const origAddr = String(data.address || '');
    const origCity = String(data.city || '');
    const origState = String(data.state || '');
    const maybeTitle = (orig, val) => (val === orig ? val : titleCase(val));
    newName = maybeTitle(origName, newName);
    newAddress = maybeTitle(origAddr, newAddress);
    newCity = maybeTitle(origCity, newCity);
    const changed = (newName !== origName) || (newAddress !== origAddr) || (newCity !== origCity) || (canonState(newState) !== canonState(origState));
    if (!changed) continue;

    const update = {
      name: newName,
      address: newAddress,
      city: newCity,
      state: canonState(newState),
      updatedAt: new Date().toISOString(),
    };
    batch.update(db.collection('parks').doc(id), update);
    writesInBatch += 1;
    updated += 1;
    if (writesInBatch >= 400) await commitBatch();

    // Safety time guard: stop early if close to timeout
    const elapsed = Date.now() - t0;
    if (elapsed > 480000) break; // ~8 minutes
  }

  await commitBatch();
  pages += 1;

  return { scanned, updated, noCoords, apiMisses, rgCalls, clustersTouched, pages, cursor, done: docs.length < pageSize };
}

exports.runParksBackfillOnce = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
    const db = admin.firestore();
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
    }
    const callerUid = context.auth.uid;
    const adminUid = await getAdminUid(db);
    if (!adminUid || callerUid !== adminUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only the owner can run backfill');
    }

    const settings = {
      mode: (data && data.mode) || 'balanced',
      capPerRun: Number(data && data.capPerRun) || 50000,
      clusterDecimals: Number(data && data.clusterDecimals) || 3,
      parseCityStateNoApi: (data && data.parseCityStateNoApi) !== false,
      refineNamesCap: Number(data && data.refineNamesCap) || 0,
      pageSize: Number(data && data.pageSize) || 600,
    };
    const controlRef = db.collection('backfill').doc('control');
    const statusRef = db.collection('backfill').doc('status');
    try {
      const ctrlSnap = await controlRef.get().catch(() => null);
      let cursor = (ctrlSnap && ctrlSnap.exists && ctrlSnap.data().cursor) || null;
      const res = await runParksBackfillBatch({ db, settings, ownerUid: adminUid, startAfterId: cursor });
      const nowIso = new Date().toISOString();
      await statusRef.set({
        ...res,
        lastRunAt: nowIso,
        lastSuccessAt: nowIso,
        settings,
      }, { merge: true });
      await controlRef.set({ cursor: res.done ? null : res.cursor, updatedAt: nowIso, lastMode: settings.mode }, { merge: true });
      // Per-run log
      const runId = nowIso.replace(/[:.]/g, '-') + '_manual';
      await db.collection('backfill').doc('logs').collection('runs').doc(runId).set({ runId, ts: nowIso, ok: true, ...res, settings });
      return { ok: true, ...res };
    } catch (e) {
      const nowIso = new Date().toISOString();
      await statusRef.set({ lastRunAt: nowIso, lastErrorAt: nowIso, lastError: (e && e.message) ? String(e.message).slice(0, 400) : String(e).slice(0, 400) }, { merge: true }).catch(() => {});
      throw new functions.https.HttpsError('internal', e?.message || 'Unknown error');
    }
  });

/**
 * HTTP wrapper for CI: invoke the same backfill once logic via HTTPS onRequest.
 * Auth model: shared secret header to avoid brittle CLI callable flows.
 *
 * Security:
 * - Requires header: X-Run-Secret matching BACKFILL_RUN_SECRET (env) or backfill.run_secret (functions config)
 * - Only proceeds if config/app.adminUid is set; runs as that owner
 *
 * Usage (GitHub Actions):
 *   curl -sS -X POST "https://us-central1-<project>.cloudfunctions.net/runParksBackfillOnceHttp" \
 *     -H "X-Run-Secret: $BACKFILL_RUN_SECRET" -H "Content-Type: application/json" \
 *     -d '{"mode":"balanced","capPerRun":40000}'
 */
exports.runParksBackfillOnceHttp = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== 'POST') {
        res.status(405).json({ ok: false, error: 'Method Not Allowed' });
        return;
      }
      const secretConfigured = getEnv('BACKFILL_RUN_SECRET', getEnv('backfill.run_secret', ''));
      if (!secretConfigured) {
        console.error('BACKFILL_RUN_SECRET not configured');
        res.status(500).json({ ok: false, error: 'Server not configured' });
        return;
      }
      const provided = String(req.headers['x-run-secret'] || '').trim();
      if (!provided || provided !== secretConfigured) {
        res.status(401).json({ ok: false, error: 'Unauthorized' });
        return;
      }

      const db = admin.firestore();
      const adminUid = await getAdminUid(db);
      if (!adminUid) {
        res.status(403).json({ ok: false, error: 'Owner not configured' });
        return;
      }

      const body = (typeof req.body === 'object' && req.body) ? req.body : {};
      const settings = {
        mode: (body && body.mode) || 'balanced',
        capPerRun: Number(body && body.capPerRun) || 50000,
        clusterDecimals: Number(body && body.clusterDecimals) || 3,
        parseCityStateNoApi: (body && body.parseCityStateNoApi) !== false,
        refineNamesCap: Number(body && body.refineNamesCap) || 0,
        pageSize: Number(body && body.pageSize) || 600,
      };

      const controlRef = db.collection('backfill').doc('control');
      const statusRef = db.collection('backfill').doc('status');
      try {
        const ctrlSnap = await controlRef.get().catch(() => null);
        let cursor = (ctrlSnap && ctrlSnap.exists && ctrlSnap.data().cursor) || null;
        const resBatch = await runParksBackfillBatch({ db, settings, ownerUid: adminUid, startAfterId: cursor });
        const nowIso = new Date().toISOString();
        await statusRef.set({
          ...resBatch,
          lastRunAt: nowIso,
          lastSuccessAt: nowIso,
          settings,
        }, { merge: true });
        await controlRef.set({ cursor: resBatch.done ? null : resBatch.cursor, updatedAt: nowIso, lastMode: settings.mode }, { merge: true });
        // Per-run log
        const runId = nowIso.replace(/[:.]/g, '-') + '_manual_http';
        await db.collection('backfill').doc('logs').collection('runs').doc(runId).set({ runId, ts: nowIso, ok: true, ...resBatch, settings });
        res.status(200).json({ ok: true, ...resBatch });
      } catch (e) {
        const nowIso = new Date().toISOString();
        await statusRef.set({ lastRunAt: nowIso, lastErrorAt: nowIso, lastError: (e && e.message) ? String(e.message).slice(0, 400) : String(e).slice(0, 400) }, { merge: true }).catch(() => {});
        res.status(500).json({ ok: false, error: e?.message || 'Unknown error' });
      }
    } catch (e) {
      res.status(500).json({ ok: false, error: 'Unhandled error' });
    }
  });

// Optional: unattended scheduler that consumes batches using backfill/control
exports.scheduledParksBackfillBatch = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB', maxInstances: 1 })
  .pubsub.schedule('every 10 minutes').timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const controlRef = db.collection('backfill').doc('control');
    const statusRef = db.collection('backfill').doc('status');
    try {
      const ctrl = await controlRef.get();
      const data = ctrl.exists ? ctrl.data() : {};
      const enabled = data && data.enabled === true; // default disabled for safety
      if (!enabled) {
        await statusRef.set({ lastRunAt: new Date().toISOString(), note: 'skipped: disabled' }, { merge: true });
        return null;
      }
      const settings = {
        mode: data && data.mode ? String(data.mode) : 'balanced',
        capPerRun: Math.max(0, Number(data && data.capPerRun) || 50000),
        clusterDecimals: Math.max(2, Math.min(5, Number(data && data.clusterDecimals) || 3)),
        parseCityStateNoApi: (data && data.parseCityStateNoApi) !== false,
        refineNamesCap: Math.max(0, Number(data && data.refineNamesCap) || 0),
        pageSize: Math.max(200, Math.min(900, Number(data && data.pageSize) || 600)),
      };
      const adminUid = await getAdminUid(db);
      const cursor = (data && data.cursor) || null;
      const res = await runParksBackfillBatch({ db, settings, ownerUid: adminUid || 'system', startAfterId: cursor });
      const nowIso = new Date().toISOString();
      await statusRef.set({ ...res, lastRunAt: nowIso, lastSuccessAt: nowIso, settings }, { merge: true });
      await controlRef.set({ cursor: res.done ? null : res.cursor, updatedAt: nowIso, lastMode: settings.mode }, { merge: true });
      const runId = nowIso.replace(/[:.]/g, '-') + '_scheduled';
      await db.collection('backfill').doc('logs').collection('runs').doc(runId).set({ runId, ts: nowIso, ok: true, ...res, settings });
      return null;
    } catch (e) {
      try {
        await statusRef.set({ lastRunAt: new Date().toISOString(), lastErrorAt: new Date().toISOString(), lastError: (e && e.message) ? String(e.message).slice(0, 400) : String(e).slice(0, 400) }, { merge: true });
      } catch (_) {}
      return null;
    }
  });

/**
 * Cloud Function: Notify park submitter on approval or denial
 *
 * Triggers: onUpdate for parks collection
 */
exports.notifyParkModerationUpdate = functions.firestore
  .document('parks/{parkId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};
    const db = admin.firestore();

    try {
      const beforeApproved = !!before.approved;
      const afterApproved = !!after.approved;
      const beforeStatus = before.reviewStatus || (beforeApproved ? 'approved' : 'pending');
      const afterStatus = after.reviewStatus || (afterApproved ? 'approved' : 'pending');

      const submitterId = after.createdByUserId || before.createdByUserId;
      const parkName = after.name || before.name || 'Park';
      if (!submitterId) return null; // nothing to notify

      // Only notify on state transitions
      if (afterStatus === 'approved' && beforeStatus !== 'approved') {
        const title = 'Park approved ✅';
        const body = `${parkName} has been approved and is now visible.`;
        const data = { type: 'park_approval', parkId: change.after.id };
        await sendNotificationsToUsers(db, [submitterId], title, body, data);
        console.log(`Approval notification sent to ${submitterId} for park ${change.after.id}`);

    // Removed: auto enqueue reverse-geocoding on approval — avoid API usage
      } else if (afterStatus === 'denied' && beforeStatus !== 'denied') {
        const reason = after.reviewMessage || 'Not approved.';
        const title = 'Park denied ❌';
        const body = `${parkName} was not approved: ${reason}`;
        const data = { type: 'park_denial', parkId: change.after.id };
        await sendNotificationsToUsers(db, [submitterId], title, body, data);
        console.log(`Denial notification sent to ${submitterId} for park ${change.after.id}`);
      }

      return null;
    } catch (e) {
      console.error('Error notifying park moderation update:', e);
      return null;
    }
  });

/**
 * Callable function: strips admin from everyone except the configured owner.
 * Requires the caller to be authenticated as the owner (adminUid).
 */
exports.stripNonOwnerAdmins = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
  }
  const db = admin.firestore();
  const callerUid = context.auth.uid;
  const adminUid = await getAdminUid(db);
  if (!adminUid) {
    throw new functions.https.HttpsError('failed-precondition', 'config/app.adminUid not set');
  }
  if (callerUid !== adminUid) {
    throw new functions.https.HttpsError('permission-denied', 'Only the owner can run this');
  }

  try {
    const snap = await db.collection('users').where('isAdmin', '==', true).get();
    const batch = db.batch();
    let count = 0;
    snap.forEach(doc => {
      if (doc.id !== adminUid) {
        batch.update(doc.ref, { isAdmin: false, updatedAt: new Date().toISOString() });
        count++;
      }
    });
    if (count > 0) {
      await batch.commit();
    }
    console.log(`Stripped admin from ${count} user(s).`);
    return { stripped: count };
  } catch (e) {
    console.error('Error stripping non-owner admins:', e);
    throw new functions.https.HttpsError('internal', e.message || 'Unknown error');
  }
});

/**
 * Helper function to send FCM notifications to multiple users
 */
async function sendNotificationsToUsers(db, userIds, title, body, data) {
  if (userIds.length === 0) return { successCount: 0, failureCount: 0 };

  // Fetch all tokens for all users
  const tokenPromises = userIds.map(userId =>
    db.collection('users').doc(userId).collection('tokens').get()
  );
  
  const tokenSnapshots = await Promise.all(tokenPromises);
  const tokens = [];
  const tokenUserMap = {};
  
  tokenSnapshots.forEach((tokenSnapshot, index) => {
    tokenSnapshot.forEach(tokenDoc => {
      const tokenData = tokenDoc.data();
      if (tokenData.token) {
        tokens.push(tokenData.token);
        tokenUserMap[tokenData.token] = {
          userId: userIds[index],
          tokenId: tokenDoc.id
        };
      }
    });
  });
  
  if (tokens.length === 0) {
    console.log('No FCM tokens found for users');
    return { successCount: 0, failureCount: 0 };
  }
  
  console.log(`Sending notification to ${tokens.length} device(s)`);
  
  // Send notification to all tokens
  const response = await admin.messaging().sendEachForMulticast({
    tokens: tokens,
    notification: { title, body },
    data: data,
    android: {
      priority: 'high',
      notification: {
        sound: 'default',
        clickAction: 'FLUTTER_NOTIFICATION_CLICK'
      }
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          category: 'NOTIFICATION'
        }
      }
    }
  });
  
  console.log(`Successfully sent ${response.successCount} notification(s)`);
  
  // Clean up invalid tokens
  if (response.failureCount > 0) {
    const invalidTokens = [];
    response.responses.forEach((resp, idx) => {
      if (!resp.success) {
        const errorCode = resp.error?.code;
        if (errorCode === 'messaging/invalid-registration-token' ||
            errorCode === 'messaging/registration-token-not-registered') {
          invalidTokens.push(tokens[idx]);
        }
      }
    });
    
    const deletePromises = invalidTokens.map(token => {
      const userInfo = tokenUserMap[token];
      if (userInfo) {
        console.log(`Removing invalid token for user ${userInfo.userId}`);
        return db.collection('users')
          .doc(userInfo.userId)
          .collection('tokens')
          .doc(userInfo.tokenId)
          .delete();
      }
      return Promise.resolve();
    });
    
    await Promise.all(deletePromises);
    console.log(`Cleaned up ${invalidTokens.length} invalid token(s)`);
  }
  
  return response;
}

// All OSM/Overpass helpers and importers removed — Google-only pipeline

/**
 * ========================
 * RETRO MERGE: OSM pin + Google sports graft (server-side)
 * ========================
 * Scans existing parks and merges missing sports from nearby Google-sourced
 * parks into OSM-sourced parks. Never deletes or moves pins; only appends
 * new courts and recomputes sportCategories. Idempotent.
 *
 * Control/status docs:
 *   retroMerge/control { cursor?: string, enabled?: boolean, pageSize?: number }
 *   retroMerge/status  { lastRunAt, lastSuccessAt, pages, scanned, updatedParks, courtsAdded, cursor, done }
 */

function normNameForMerge(name) {
  const s = String(name || '').toLowerCase();
  return s
    .replace(/[\u2014\u2013]/g, '-')
    .replace(/[^a-z0-9\s-]/g, ' ')
    .replace(/\b(park|recreation|rec|center|courts?|basketball|tennis|pickleball)\b/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

function similarNameMerge(a, b) {
  const na = normNameForMerge(a);
  const nb = normNameForMerge(b);
  if (!na || !nb) return false;
  if (na === nb) return true;
  return na.includes(nb) || nb.includes(na);
}

function haversineMiles(lat1, lon1, lat2, lon2) {
  const R = 3958.7613; // Earth radius in miles
  const toRad = (d) => d * Math.PI / 180.0;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.asin(Math.min(1, Math.sqrt(a)));
  return R * c;
}

function isGooglePark(doc) {
  const s = String((doc && doc.source) || '').toLowerCase();
  const a = String((doc && doc.sourceAttribution) || '').toLowerCase();
  return s === 'places' || s.includes('google') || a.includes('google');
}

function isOsmPark(doc) {
  const s = String((doc && doc.source) || '').toLowerCase();
  const a = String((doc && doc.sourceAttribution) || '').toLowerCase();
  return s.includes('osm') || a.includes('openstreetmap');
}

function sportCategoryFromType(st) {
  const s = String(st || '').toLowerCase();
  if (s.includes('pickle')) return 'pickleball';
  if (s.includes('tennis')) return 'tennis';
  return 'basketball';
}

function recomputeSportCategories(courts) {
  const set = new Set();
  for (const c of (courts || [])) {
    set.add(sportCategoryFromType(c && c.sportType));
  }
  return Array.from(set).sort();
}

function mergeCourtsIfAddsValue(existing, incoming) {
  if (!existing || !incoming) return null;
  const existingCourts = Array.isArray(existing.courts) ? existing.courts : [];
  const incomingCourts = Array.isArray(incoming.courts) ? incoming.courts : [];
  const existingSports = new Set(existingCourts.map(c => c && c.sportType));
  const incomingSports = new Set(incomingCourts.map(c => c && c.sportType));
  const missing = Array.from(incomingSports).filter(s => s && !existingSports.has(s));
  if (missing.length === 0) return null;
  let nextNumber = 0;
  for (const c of existingCourts) {
    if (c && Number(c.courtNumber) > nextNumber) nextNumber = Number(c.courtNumber);
  }
  const additions = [];
  const nowIso = new Date().toISOString();
  for (const s of missing) {
    const src = incomingCourts.find(c => c && c.sportType === s) || {};
    nextNumber += 1;
    additions.push({
      id: `c${nextNumber}`,
      courtNumber: nextNumber,
      playerCount: 0,
      sportType: s,
      type: src.type || (String(s).includes('tennis') ? 'tennisSingles' : (String(s).includes('pickle') ? 'pickleballSingles' : 'fullCourt')),
      hasLighting: !!src.hasLighting,
      isHalfCourt: !!src.isHalfCourt,
      isIndoor: !!src.isIndoor,
      surface: src.surface || null,
      lastUpdated: nowIso,
      condition: src.condition || 'good',
      customName: src.customName || null,
      conditionNotes: src.conditionNotes || null,
      gotNextQueue: Array.isArray(src.gotNextQueue) ? src.gotNextQueue : [],
      source: incoming.source || 'google_places',
      sourceAttribution: incoming.sourceAttribution || 'Google Places',
    });
  }
  if (!additions.length) return null;
  const mergedCourts = existingCourts.concat(additions);
  return {
    ...existing,
    courts: mergedCourts,
    sportCategories: recomputeSportCategories(mergedCourts),
    updatedAt: nowIso,
  };
}

async function runRetroMergeBatch(db, { pageSize = 1000, proximityMiles = 0.12, startAfterId = null, dryRun = false } = {}) {
  // Read only the fields we actually need to cut payload and speed up scans
  const neededFields = ['name', 'latitude', 'longitude', 'courts', 'source', 'sourceAttribution'];
  let base = db
    .collection('parks')
    // Order by latitude so OSM and Google docs intermix in pages.
    // Using only a single-field order avoids the need for composite indexes.
    .orderBy('latitude')
    .select(...neededFields);
  if (startAfterId) {
    try {
      const cur = await db.collection('parks').doc(startAfterId).get();
      if (cur.exists) base = base.startAfter(cur);
    } catch (_) {}
  }
  const snap = await base.limit(pageSize).get();
  if (snap.empty) return { pages: 0, scanned: 0, updatedParks: 0, courtsAdded: 0, cursor: null, done: true };

  const docs = snap.docs.map(d => ({ id: d.id, ...(d.data() || {}) }));

  // Use coarser geo-bins (3 decimals ~ 110m) and include neighbor bins to
  // catch pairs that fall on bin boundaries. We still enforce haversine distance
  // and a relaxed name match to avoid false merges.
  const DECIMALS = 3;
  const STEP = 1 / Math.pow(10, DECIMALS); // 0.001 for 3 decimals
  const roundN = (v) => Number(v).toFixed(DECIMALS);
  const keyOf = (lat, lon) => `${roundN(lat)},${roundN(lon)}`;

  // Build bins for GOOGLE parks only to keep candidate sets small
  const googleBins = new Map();
  for (const p of docs) {
    const lat = Number(p.latitude);
    const lon = Number(p.longitude);
    if (!isFinite(lat) || !isFinite(lon)) continue;
    if (!isGooglePark(p)) continue;
    const key = keyOf(lat, lon);
    const arr = googleBins.get(key) || [];
    arr.push(p);
    googleBins.set(key, arr);
  }

  function neighborKeys(lat, lon) {
    const latR = Number(roundN(lat));
    const lonR = Number(roundN(lon));
    const keys = [];
    for (let dLat of [-STEP, 0, STEP]) {
      for (let dLon of [-STEP, 0, STEP]) {
        keys.push(keyOf(latR + dLat, lonR + dLon));
      }
    }
    return keys;
  }

  let updatedParks = 0, courtsAdded = 0, scanned = docs.length;
  let writes = 0;
  let batch = db.batch();
  const commit = async () => { if (!dryRun && writes > 0) { await batch.commit(); batch = db.batch(); writes = 0; } };

  // Iterate OSM parks and attempt merges against candidate Google parks
  for (const osm of docs) {
    if (!isOsmPark(osm)) continue;
    const la = Number(osm.latitude);
    const lo = Number(osm.longitude);
    if (!isFinite(la) || !isFinite(lo)) continue;

    const candidateLists = neighborKeys(la, lo).map(k => googleBins.get(k) || []);
    const candidates = [].concat(...candidateLists);
    if (!candidates.length) continue;

    // Work on a local copy of courts for incremental merges from multiple candidates
    let localCourts = Array.isArray(osm.courts) ? osm.courts : [];
    let pendingUpdate = null;
    for (const gp of candidates) {
      // Quick filters
      if (!similarNameMerge(osm.name, gp.name)) continue;
      const d = haversineMiles(la, lo, Number(gp.latitude), Number(gp.longitude));
      if (d > proximityMiles) continue;

      const merged = mergeCourtsIfAddsValue({ courts: localCourts }, gp);
      if (merged) {
        const before = Array.isArray(localCourts) ? localCourts.length : 0;
        const after = Array.isArray(merged.courts) ? merged.courts.length : 0;
        if (after > before) courtsAdded += (after - before);
        localCourts = merged.courts;
        pendingUpdate = merged;
      }
    }

    if (pendingUpdate) {
      updatedParks += 1;
      const ref = db.collection('parks').doc(osm.id);
      if (!dryRun) {
        batch.update(ref, pendingUpdate);
        writes += 1;
        if (writes >= 400) await commit();
      }
    }
  }

  await commit();
  const cursor = docs[docs.length - 1].id;
  const done = docs.length < pageSize;
  return { pages: 1, scanned, updatedParks, courtsAdded, cursor, done };
}

exports.runRetroMergeOnce = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
    const db = admin.firestore();
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
    }
    const callerUid = context.auth.uid;
    const adminUid = await getAdminUid(db);
    if (!adminUid || callerUid !== adminUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only the owner can run retro merge');
    }
    const controlRef = db.collection('retroMerge').doc('control');
    const statusRef = db.collection('retroMerge').doc('status');
    const pageSize = Math.max(400, Math.min(3000, Number(data && data.pageSize) || 1200));
    const dryRun = !!(data && data.dryRun);
    try {
      const ctrl = await controlRef.get().catch(() => null);
      const cursor = ctrl && ctrl.exists ? (ctrl.data().cursor || null) : null;
      const res = await runRetroMergeBatch(db, { pageSize, startAfterId: cursor, dryRun });
      const nowIso = new Date().toISOString();
      await statusRef.set({ lastRunAt: nowIso, lastSuccessAt: nowIso, ...res, pageSize, dryRun }, { merge: true });
      await controlRef.set({ cursor: res.done ? null : res.cursor, updatedAt: nowIso }, { merge: true });
      return { ok: true, ...res, pageSize, dryRun };
    } catch (e) {
      const nowIso = new Date().toISOString();
      await statusRef.set({ lastRunAt: nowIso, lastErrorAt: nowIso, lastError: (e && e.message) ? String(e.message).slice(0, 400) : String(e).slice(0, 400) }, { merge: true }).catch(() => {});
      throw new functions.https.HttpsError('internal', e?.message || 'Unknown error');
    }
  });

// HTTP wrapper for CI (GridHub/GitHub). Requires X-Run-Secret header.
exports.runRetroMergeOnceHttp = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method Not Allowed' }); return; }
      const secretConfigured = getEnv('BACKFILL_RUN_SECRET', getEnv('backfill.run_secret', ''));
      const provided = String(req.headers['x-run-secret'] || req.headers['x-runner-secret'] || '').trim();
      if (!secretConfigured || !provided || provided !== secretConfigured) { res.status(401).json({ ok: false, error: 'Unauthorized' }); return; }
      const db = admin.firestore();
      const controlRef = db.collection('retroMerge').doc('control');
      const statusRef = db.collection('retroMerge').doc('status');
      const body = (typeof req.body === 'object' && req.body) ? req.body : {};
      const pageSize = Math.max(400, Math.min(3000, Number(body.pageSize) || 1200));
      const dryRun = body.dryRun === true;
      const ctrlSnap = await controlRef.get().catch(() => null);
      const cursor = ctrlSnap && ctrlSnap.exists ? (ctrlSnap.data().cursor || null) : null;
      const resBatch = await runRetroMergeBatch(db, { pageSize, startAfterId: cursor, dryRun });
      const nowIso = new Date().toISOString();
      await statusRef.set({ lastRunAt: nowIso, lastSuccessAt: nowIso, ...resBatch, pageSize, dryRun }, { merge: true });
      await controlRef.set({ cursor: resBatch.done ? null : resBatch.cursor, updatedAt: nowIso }, { merge: true });
      res.status(200).json({ ok: true, ...resBatch, pageSize, dryRun });
    } catch (e) {
      res.status(500).json({ ok: false, error: e?.message || 'Unhandled error' });
    }
  });

/**
 * Owner-callable: Sweep Retro-merge across all parks in one session (looped)
 */
exports.runRetroMergeAll = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
    const db = admin.firestore();
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
    }
    const callerUid = context.auth.uid;
    const adminUid = await getAdminUid(db);
    if (!adminUid || callerUid !== adminUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only the owner can run retro merge');
    }
    const pageSize = Math.max(400, Math.min(3000, Number(data && data.pageSize) || 1200));
    const dryRun = !!(data && data.dryRun);
    const t0 = Date.now();
    let agg = { pages: 0, scanned: 0, updatedParks: 0, courtsAdded: 0 };
    let cursor = null;
    let done = false;
    do {
      const ctrlSnap = await db.collection('retroMerge').doc('control').get().catch(() => null);
      cursor = ctrlSnap && ctrlSnap.exists ? (ctrlSnap.data().cursor || null) : null;
      const out = await runRetroMergeBatch(db, { pageSize, startAfterId: cursor, dryRun });
      agg.pages += out.pages;
      agg.scanned += out.scanned;
      agg.updatedParks += out.updatedParks;
      agg.courtsAdded += out.courtsAdded;
      done = !!out.done;
      // Check time headroom (~20s)
      if (!done && (Date.now() - t0) > 520000) break;
    } while (!done);
    return { ok: true, ...agg, done, pageSize, dryRun };
  });

/**
 * HTTP: Sweep Retro-merge fully with shared secret
 */
exports.runRetroMergeAllHttp = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method Not Allowed' }); return; }
      const secretConfigured = getEnv('BACKFILL_RUN_SECRET', getEnv('backfill.run_secret', ''));
      const provided = String(req.headers['x-run-secret'] || req.headers['x-runner-secret'] || '').trim();
      if (!secretConfigured || !provided || provided !== secretConfigured) { res.status(401).json({ ok: false, error: 'Unauthorized' }); return; }
      const db = admin.firestore();
      const pageSize = Math.max(400, Math.min(3000, Number((req.body && req.body.pageSize) || 1200)));
      const dryRun = (req.body && req.body.dryRun) === true;
      const t0 = Date.now();
      let agg = { pages: 0, scanned: 0, updatedParks: 0, courtsAdded: 0 };
      let cursor = null;
      let done = false;
      do {
        const ctrlSnap = await db.collection('retroMerge').doc('control').get().catch(() => null);
        cursor = ctrlSnap && ctrlSnap.exists ? (ctrlSnap.data().cursor || null) : null;
        const out = await runRetroMergeBatch(db, { pageSize, startAfterId: cursor, dryRun });
        agg.pages += out.pages;
        agg.scanned += out.scanned;
        agg.updatedParks += out.updatedParks;
        agg.courtsAdded += out.courtsAdded;
        done = !!out.done;
        if (!done && (Date.now() - t0) > 520000) break;
      } while (!done);
      res.status(200).json({ ok: true, ...agg, done, pageSize, dryRun });
    } catch (e) {
      res.status(500).json({ ok: false, error: e?.message || 'Unhandled error' });
    }
  });

/**
 * Owner-callable: Retro-merge sweep only (Fix City/State removed from sweep)
 * Notes:
 * - Previously this endpoint ran both Fix City/State and Retro-merge.
 * - Per owner request, Fix City/State has completed and is no longer part of the one-time sweep.
 * - We keep the shape of the response with a no-op "fix" block for UI compatibility.
 */
exports.runOneTimeSweepAll = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
    const db = admin.firestore();
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
    }
    const callerUid = context.auth.uid;
    const adminUid = await getAdminUid(db);
    if (!adminUid || callerUid !== adminUid) {
      throw new functions.https.HttpsError('permission-denied', 'Only the owner can run this');
    }
    const retroPageSize = Math.max(400, Math.min(3000, Number(data && data.retroPageSize) || 1200));
    const t0 = Date.now();
    // Part 1: Fix City/State intentionally omitted from this sweep (completed previously)
    const fix = { pages: 0, scanned: 0, updated: 0, skippedEmpty: 0, ambiguous: 0, done: true, note: 'omitted_from_sweep' };
    // Part 2: Retro-merge for remaining time
    let retro = { pages: 0, scanned: 0, updatedParks: 0, courtsAdded: 0, done: false };
    {
      let done = false;
      do {
        const ctrlSnap = await db.collection('retroMerge').doc('control').get().catch(() => null);
        const cursor = ctrlSnap && ctrlSnap.exists ? (ctrlSnap.data().cursor || null) : null;
        const out = await runRetroMergeBatch(db, { pageSize: retroPageSize, startAfterId: cursor, dryRun: false });
        retro.pages += out.pages;
        retro.scanned += out.scanned;
        retro.updatedParks += out.updatedParks;
        retro.courtsAdded += out.courtsAdded;
        done = !!out.done;
        retro.done = done;
        if (!done && (Date.now() - t0) > 520000) break;
      } while (!retro.done);
    }
    return { ok: true, fix, retro };
  });

/**
 * HTTP: Run Retro-merge sweep only with one request (shared secret)
 * Fix City/State has been removed from this combined endpoint.
 */
exports.runOneTimeSweepAllHttp = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onRequest(async (req, res) => {
    try {
      if (req.method !== 'POST') { res.status(405).json({ ok: false, error: 'Method Not Allowed' }); return; }
      const secretConfigured = getEnv('BACKFILL_RUN_SECRET', getEnv('backfill.run_secret', ''));
      const provided = String(req.headers['x-run-secret'] || req.headers['x-runner-secret'] || '').trim();
      if (!secretConfigured || !provided || provided !== secretConfigured) { res.status(401).json({ ok: false, error: 'Unauthorized' }); return; }
      const db = admin.firestore();
      const retroPageSize = Math.max(400, Math.min(3000, Number((req.body && req.body.retroPageSize) || 1200)));
      const t0 = Date.now();
      // Fix City/State intentionally omitted from this sweep (completed previously)
      const fix = { pages: 0, scanned: 0, updated: 0, skippedEmpty: 0, ambiguous: 0, done: true, note: 'omitted_from_sweep' };
      // Retro-merge loop
      let retro = { pages: 0, scanned: 0, updatedParks: 0, courtsAdded: 0, done: false };
      {
        let done = false;
        do {
          const ctrlSnap = await db.collection('retroMerge').doc('control').get().catch(() => null);
          const cursor = ctrlSnap && ctrlSnap.exists ? (ctrlSnap.data().cursor || null) : null;
          const out = await runRetroMergeBatch(db, { pageSize: retroPageSize, startAfterId: cursor, dryRun: false });
          retro.pages += out.pages;
          retro.scanned += out.scanned;
          retro.updatedParks += out.updatedParks;
          retro.courtsAdded += out.courtsAdded;
          done = !!out.done;
          retro.done = done;
          if (!done && (Date.now() - t0) > 520000) break;
        } while (!retro.done);
      }
      res.status(200).json({ ok: true, fix, retro });
    } catch (e) {
      res.status(500).json({ ok: false, error: e?.message || 'Unhandled error' });
    }
  });

// Optional scheduler: disabled by default unless retroMerge/control.enabled == true
// Now runs every 2 minutes with a soft cooldown and auto-disables when done
exports.scheduledRetroMerge = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB', maxInstances: 1 })
  .pubsub.schedule('every 2 minutes').timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const controlRef = db.collection('retroMerge').doc('control');
    const statusRef = db.collection('retroMerge').doc('status');
    try {
      const ctrl = await controlRef.get().catch(() => null);
      const cfg = ctrl && ctrl.exists ? (ctrl.data() || {}) : {};
      const enabled = cfg.enabled === true;
      if (!enabled) {
        await statusRef.set({ lastRunAt: new Date().toISOString(), note: 'skipped: disabled' }, { merge: true });
        return null;
      }

      // Optional cooldown to avoid thrashing if schedule is very frequent
      const statusSnap = await statusRef.get().catch(() => null);
      const status = statusSnap && statusSnap.exists ? (statusSnap.data() || {}) : {};
      const lastSuccessAt = status.lastSuccessAt ? new Date(status.lastSuccessAt) : null;
      const minIntervalMinutes = Math.max(1, Math.min(10, Number(cfg.minIntervalMinutes) || 2));
      if (lastSuccessAt && (Date.now() - lastSuccessAt.getTime()) < minIntervalMinutes * 60 * 1000) {
        await statusRef.set({ lastRunAt: new Date().toISOString(), note: `skipped: cooldown ${minIntervalMinutes}m` }, { merge: true });
        return null;
      }

      // Multi-page loop per tick (faster): honor optional caps from control
      const pageSize = Math.max(400, Math.min(3000, Number(cfg.pageSize) || 1200));
      const budgetMs = Math.max(60_000, Math.min(520_000, Number(cfg.maxMillisPerRun) || 480_000));
      const maxPages = Math.max(1, Math.min(10_000, Number(cfg.maxPagesPerRun) || 999_999));

      const t0 = Date.now();
      let cursor = cfg.cursor || null;
      let agg = { pages: 0, scanned: 0, updatedParks: 0, courtsAdded: 0 };
      let done = false;
      do {
        const resBatch = await runRetroMergeBatch(db, { pageSize, startAfterId: cursor, dryRun: false });
        agg.pages += resBatch.pages;
        agg.scanned += resBatch.scanned;
        agg.updatedParks += resBatch.updatedParks;
        agg.courtsAdded += resBatch.courtsAdded;
        cursor = resBatch.done ? null : resBatch.cursor;
        const nowIso = new Date().toISOString();
        await statusRef.set({ lastRunAt: nowIso, lastSuccessAt: nowIso, ...agg, cursor, pageSize, note: 'running' }, { merge: true });
        await controlRef.set({ cursor, updatedAt: nowIso }, { merge: true });
        done = !!resBatch.done;
        if (done) break;
        if ((Date.now() - t0) > budgetMs) break;
        if (agg.pages >= maxPages) break;
      } while (true);

      const nowIso = new Date().toISOString();
      await statusRef.set({ lastRunAt: nowIso, lastSuccessAt: nowIso, ...agg, cursor, pageSize, done, note: done ? 'pass complete' : `paused (<${Math.round((budgetMs - (Date.now() - t0)) / 1000)}s left)` }, { merge: true });
      await controlRef.set({ cursor: done ? null : cursor, updatedAt: nowIso }, { merge: true });

      // Auto-disable when fully done to avoid unnecessary reads/costs
      if (done) {
        await controlRef.set({ enabled: false, done: true, updatedAt: nowIso }, { merge: true });
        await statusRef.set({ done: true }, { merge: true });
      }
      return null;
    } catch (e) {
      try {
        await statusRef.set({ lastRunAt: new Date().toISOString(), lastErrorAt: new Date().toISOString(), lastError: (e && e.message) ? String(e.message).slice(0, 400) : String(e).slice(0, 400) }, { merge: true });
      } catch (_) {}
      return null;
    }
  });

/**
// Removed: all Google Places import/backfill helpers and endpoints — no more imports

// importPlacesForCitySimple removed — Google-only pipeline

// Overpass-based backlog seeder removed (Google-only pipeline)

// HTTP wrapper for CI/admin: seed Places backlog for a state
// Overpass-based backlog seeder HTTP removed (Google-only pipeline)

// Scheduled: seed Places backlog across all states, rotating West→East
// Overpass backlog seeding (all states) removed

// Scheduler: consume one Places backlog task per run
// Now honors a Firestore config kill switch:
//   imports/places/config/drainer { enabled: boolean, maxTasksPerRun?: number, estCallsPerCity?: number }
// Default: disabled until explicitly enabled to prevent accidental API burn.
// Geoapify/queue-based city batch backfill removed

/**
 * Aggressive backlog seeder: keeps imports/places/backlog filled so the drainer
 * always has work. Rotates West→East and seeds multiple states per run.
 *
 * Config (Firestore doc: imports/places/config):
 *  - targetBacklog: desired pending tasks (default 600)
 *  - citiesPerState: max cities to add per state per seeding (default 80)
 *  - statesPerRun: how many states to seed per run (default 3)
 *  - enabled: boolean (default true)
 *
 * Status/progress is written to imports/places with lastEnsureAt/lastEnsureNote/nextIndex
 */
// Backlog capacity seeder removed (Google-only pipeline)

/**
 * HTTP: Run the Places city backfill batch immediately (same logic as the scheduler).
 * Security: requires X-Run-Secret header matching BACKFILL_RUN_SECRET/backfill.run_secret.
 * Optional body: { maxTasksPerRun?: number }
 */
// HTTP backlog batch runner removed

/**
 * HTTP: Direct Geoapify importer (no queue/drainer). Writes parks immediately.
 * Security: requires X-Run-Secret header matching BACKFILL_RUN_SECRET/backfill.run_secret.
 * Body: { city, state, lat, lon, radiusMeters, maxCreates, dryRun, inlineReverse }
 */
// GeoSimple import removed

/**
 * Scheduled: Rotate through configured target cities and run geoSimpleImport once per tick.
 * Config path: imports/geoSimple (doc)
 *  - enabled: boolean (default false)
 *  - useWindow: boolean (default true; honors nightly window)
 *  - nextIndex: number (managed by scheduler)
 * Targets path: imports/geoSimple/targets (collection)
 *  - { city, state, lat, lon, radiusKm, maxCreates }
 */
// GeoSimple scheduler removed

/**
 * HTTP: Seed imports/geoSimple/targets with curated Tier 1–3 metro split targets.
 * One‑time admin endpoint so you don’t have to create dozens of docs manually.
 *
 * Security: requires X-Run-Secret matching BACKFILL_RUN_SECRET/backfill.run_secret
 * Body (optional):
 *  - preset: 'all' | 'tier1' | 'tier2' | 'tier3' (default 'all')
 *  - overwrite: boolean (default false) — if true, update existing targets' radius/maxCreates
 *  - dryRun: boolean (default false) — preview without writing
 *  - enableNow: boolean (default false) — also set imports/geoSimple.enabled=true and optionally useWindow
 *  - useWindow: boolean (default true) — when enableNow=true, sets nightly window honoring flag
 */
// GeoSimple seeding HTTP removed

/**
 * HTTP: Ensure Places backlog capacity now (same as scheduledEnsurePlacesBacklogCapacity, one pass).
 * Security: X-Run-Secret as above.
 */
// Backlog ensure HTTP removed

// OSM city backlog scheduler removed (Google-only pipeline)

/**
 * Build per-state and per-city indices for diagnostics (counts and lastUpdated)
 * Runs every 6 hours. Writes to stats/states/<state> and stats/states/<state>/cities/<city>
 */
// Google-Places-only scheduler: iterate imports/googlePlaces/targets
// Removed: scheduledGooglePlacesBackfill — no more city imports

/**
 * HTTP: Run a one-off Google Places import for a single city/target.
 * Security: requires X-Run-Secret matching BACKFILL_RUN_SECRET/backfill.run_secret.
 * Body: { city, state, lat?, lon?, radiusKm?, maxCreates?, dryRun? }
 */
// Removed: runGooglePlacesImportForCityHttp — no more ad-hoc imports

exports.scheduledBuildStateCityIndex = functions.pubsub
  .schedule('every 6 hours')
  .timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const nowIso = new Date().toISOString();
    function sportKey(raw) {
      const s = String(raw || '').toLowerCase();
      if (s.includes('pickle')) return 'pickleball';
      if (s.includes('tennis')) return 'tennis';
      if (s.includes('basket')) return 'basketball';
      return 'other';
    }
    for (const state of WEST_TO_EAST_STATE_ORDER) {
      try {
        const snap = await db.collection('parks').where('state', '==', state).get();
        const cities = new Map();
        let total = 0;
        const sportTotals = { basketball: 0, pickleball: 0, tennis: 0, other: 0 };
        snap.forEach(doc => {
          total += 1;
          const d = doc.data();
          const city = (d.city || 'Unknown').trim() || 'Unknown';
          const c = cities.get(city) || { count: 0, latest: '', minLat: 90, maxLat: -90, minLon: 180, maxLon: -180, sportCounts: { basketball: 0, pickleball: 0, tennis: 0, other: 0 } };
          c.count += 1;
          const ts = d.updatedAt || d.createdAt || '';
          if (ts && (!c.latest || ts > c.latest)) c.latest = ts;
          const lat = Number(d.latitude);
          const lon = Number(d.longitude);
          if (isFinite(lat) && isFinite(lon)) {
            if (lat < c.minLat) c.minLat = lat;
            if (lat > c.maxLat) c.maxLat = lat;
            if (lon < c.minLon) c.minLon = lon;
            if (lon > c.maxLon) c.maxLon = lon;
          }
          // Aggregate sport categories by unique category per park (avoid court inflation)
          const courts = Array.isArray(d.courts) ? d.courts : [];
          const seen = new Set();
          for (const ct of courts) {
            const key = sportKey(ct && ct.sportType);
            if (!seen.has(key)) {
              c.sportCounts[key] = (c.sportCounts[key] || 0) + 1;
              sportTotals[key] = (sportTotals[key] || 0) + 1;
              seen.add(key);
            }
          }
          cities.set(city, c);
        });

        const stateRef = db.collection('stats').doc('states').collection('states').doc(state);
        await stateRef.set({ state, totalParks: total, sportCountsTotal: sportTotals, updatedAt: nowIso }, { merge: true });

        const batchWrites = [];
        cities.forEach((val, key) => {
          const cityRef = stateRef.collection('cities').doc(key.replaceAll('/', '_'));
          batchWrites.push(cityRef.set({
            city: key,
            count: val.count,
            latest: val.latest || null,
            bbox: { minLat: val.minLat, maxLat: val.maxLat, minLon: val.minLon, maxLon: val.maxLon },
            sportCounts: val.sportCounts,
            updatedAt: nowIso,
          }, { merge: true }));
        });
        if (batchWrites.length) await Promise.all(batchWrites);
      } catch (e) {
        console.warn('scheduledBuildStateCityIndex error for', state, e.message || e);
      }
    }
    return null;
  });

// Removed: Google West→East cursor (scheduler and HTTP) — no automated Google imports

/**
 * Cloud Function: Send push notifications when a user checks into a court
 * 
 * Triggers: onCreate for check-ins collection
 * Flow:
 * 1. Extract parkId from the new check-in document
 * 2. Query users who have this park in favorites with notifications enabled
 * 3. Fetch FCM tokens for each user
 * 4. Send FCM notification with click action to open the park
 * 5. Clean up invalid/expired tokens
 */
exports.sendCheckinNotification = functions.firestore
  .document('checkins/{checkinId}')
  .onCreate(async (snapshot, context) => {
    const checkin = snapshot.data();
    const db = admin.firestore();
    
    try {
      // 1. Extract check-in details
      const parkId = checkin.parkId;
      const userId = checkin.userId;
      const courtName = checkin.courtName || 'a court';
      const playerCount = checkin.playerCount || 1;
      
      // 2. Fetch park details for notification content
      const parkDoc = await db.collection('parks').doc(parkId).get();
      if (!parkDoc.exists) {
        console.log('Park not found:', parkId);
        return null;
      }
      const parkName = parkDoc.data().name;
      
      // 3. Fetch user who checked in (for display name)
      const userDoc = await db.collection('users').doc(userId).get();
      const displayName = userDoc.exists ? userDoc.data().displayName : 'Someone';
      
      // Prepare common notification payload
      const title = `🏀 ${parkName}`;
      const body = `${displayName} just checked in with ${playerCount} player${playerCount > 1 ? 's' : ''} on ${courtName}`;
      const data = {
        type: 'checkin',
        parkId: parkId,
        courtName: courtName,
        click_action: 'FLUTTER_NOTIFICATION_CLICK'
      };

      let totalSent = 0;

      // 4A. Notify users who favorited this park (and enabled)
      try {
        const usersSnapshot = await db.collection('users')
          .where(`favoriteNotifications.${parkId}`, '==', true)
          .get();
        if (!usersSnapshot.empty) {
          const targetUserIds = [];
          usersSnapshot.forEach(doc => {
            if (doc.id !== userId) targetUserIds.push(doc.id);
          });
          if (targetUserIds.length > 0) {
            const favResp = await sendNotificationsToUsers(db, targetUserIds, title, body, data);
            totalSent += favResp.successCount;
          }
        } else {
          console.log('No users with notifications enabled for park:', parkId);
        }
      } catch (e) {
        console.error('Error sending favorite park notifications:', e);
      }

      // 4B. Notify ALL other members of groups this user belongs to (no per-group opt-in)
      try {
        const groupsSnap = await db.collection('groups')
          .where('memberIds', 'array-contains', userId)
          .get();
        if (!groupsSnap.empty) {
          const notifySet = new Set();
          groupsSnap.forEach(groupDoc => {
            const groupData = groupDoc.data();
            const memberIds = Array.isArray(groupData.memberIds) ? groupData.memberIds : [];
            memberIds.forEach(id => { if (id !== userId) notifySet.add(id); });
          });

          const notifyUserIds = Array.from(notifySet);
          if (notifyUserIds.length > 0) {
            // Reuse the same title (park name) and body; this avoids duplicate pushes across overlapping groups
            const groupResp = await sendNotificationsToUsers(db, notifyUserIds, title, body, data);
            totalSent += groupResp.successCount;
          }
        }
      } catch (e) {
        console.error('Error sending group member notifications:', e);
      }

      return { success: true, sent: totalSent };
      
    } catch (error) {
      console.error('Error sending check-in notification:', error);
      return { success: false, error: error.message };
    }
  });

/**
 * Cloud Function: Send push notification for friend requests
 * 
 * Triggers: onCreate for notifications collection (type: friend_request)
 */
exports.sendFriendRequestNotification = functions.firestore
  .document('notifications/{notificationId}')
  .onCreate(async (snapshot, context) => {
    const notification = snapshot.data();
    const db = admin.firestore();
    
    if (notification.type !== 'friend_request') return null;
    
    try {
      const userId = notification.userId;
      const senderName = notification.senderName;
      const title = notification.title || 'New Friend Request';
      const body = notification.body || `${senderName} sent you a friend request`;
      const data = {
        type: 'friend_request',
        click_action: 'FLUTTER_NOTIFICATION_CLICK'
      };
      
      const response = await sendNotificationsToUsers(db, [userId], title, body, data);
      console.log(`Friend request notification sent to user ${userId}`);
      return { success: true, sent: response.successCount };
      
    } catch (error) {
      console.error('Error sending friend request notification:', error);
      return { success: false, error: error.message };
    }
  });

/**
 * Scheduled Function: Prune stale queue entries across all parks
 *
 * Runs periodically and removes any queue players with no activity for > 60 minutes.
 */
exports.pruneStaleQueueEntries = functions.pubsub
  .schedule('every 15 minutes')
  .timeZone('Etc/UTC')
  .onRun(async (context) => {
    const db = admin.firestore();
    const now = new Date();
    const timeoutMs = QUEUE_TIMEOUT_MINUTES * 60 * 1000;

    try {
      const parksSnap = await db.collection('parks').get();
      if (parksSnap.empty) return null;

      const updates = [];
      parksSnap.forEach((doc) => {
        const parkData = doc.data();
        const courts = Array.isArray(parkData.courts) ? parkData.courts : [];
        let hasChanges = false;

        const updatedCourts = courts.map((court) => {
          const queue = Array.isArray(court.gotNextQueue) ? court.gotNextQueue : [];
          const filtered = queue.filter((player) => {
            const joinedAt = player.joinedAt ? new Date(player.joinedAt) : now;
            const lastActivity = player.lastActivity ? new Date(player.lastActivity) : joinedAt;
            return now - lastActivity < timeoutMs;
          });
          if (filtered.length !== queue.length) {
            hasChanges = true;
            return {
              ...court,
              gotNextQueue: filtered,
              lastUpdated: now.toISOString(),
            };
          }
          return court;
        });

        if (hasChanges) {
          updates.push(
            db.collection('parks').doc(doc.id).update({
              courts: updatedCourts,
              updatedAt: now.toISOString(),
            })
          );
        }
      });

      if (updates.length) {
        await Promise.all(updates);
        console.log(`Pruned queues on ${updates.length} park(s)`);
      } else {
        console.log('No stale queue entries to prune');
      }
      return null;
    } catch (e) {
      console.error('Error pruning stale queue entries:', e);
      return null;
    }
  });

/**
 * Cloud Function: Send push notification for game invites
 * 
 * Triggers: onCreate for notifications collection (type: game_invite or now_playing)
 */
exports.sendGameNotification = functions.firestore
  .document('notifications/{notificationId}')
  .onCreate(async (snapshot, context) => {
    const notification = snapshot.data();
    const db = admin.firestore();
    
    if (notification.type !== 'game_invite' && notification.type !== 'now_playing') return null;
    
    try {
      const userId = notification.userId;
      const title = notification.title;
      const body = notification.body;
      const data = {
        type: notification.type,
        parkName: notification.parkName || '',
        click_action: 'FLUTTER_NOTIFICATION_CLICK'
      };
      
      if (notification.scheduledTime) {
        data.scheduledTime = notification.scheduledTime;
      }
      if (notification.courtNumber) {
        data.courtNumber = notification.courtNumber.toString();
      }
      
      const response = await sendNotificationsToUsers(db, [userId], title, body, data);
      console.log(`${notification.type} notification sent to user ${userId}`);
      return { success: true, sent: response.successCount };
      
    } catch (error) {
      console.error('Error sending game notification:', error);
      return { success: false, error: error.message };
    }
  });

/**
 * Cloud Function: Update court player counts when check-ins are created
 * 
 * Triggers: onCreate for checkins collection
 * Flow:
 * 1. Extract parkId and courtId from new check-in
 * 2. Query active check-ins for that court
 * 3. Update the park document with the current player count
 */
exports.updateCourtPlayerCountOnCheckIn = functions.firestore
  .document('checkins/{checkinId}')
  .onCreate(async (snapshot, context) => {
    const checkin = snapshot.data();
    const db = admin.firestore();
    
    try {
      const parkId = checkin.parkId;
      const courtNumber = checkin.courtNumber;
      
      if (!parkId || courtNumber === undefined || courtNumber === null) {
        console.log('Missing parkId or courtNumber in check-in');
        return null;
      }
      
      // Count active check-ins for this court
      const activeCheckIns = await db.collection('checkins')
        .where('parkId', '==', parkId)
        .where('courtNumber', '==', courtNumber)
        .where('isActive', '==', true)
        .get();
      
      const playerCount = activeCheckIns.size;
      console.log(`Court ${courtNumber} at park ${parkId} now has ${playerCount} active check-ins`);
      
      // Update the park document
      const parkRef = db.collection('parks').doc(parkId);
      const parkDoc = await parkRef.get();
      
      if (!parkDoc.exists) {
        console.log('Park not found:', parkId);
        return null;
      }
      
      const parkData = parkDoc.data();
      const courts = parkData.courts || [];
      
      // Find and update the specific court by courtNumber
      const courtIndex = courts.findIndex(c => c.courtNumber === courtNumber);
      if (courtIndex !== -1) {
        courts[courtIndex].playerCount = playerCount;
        courts[courtIndex].lastUpdated = admin.firestore.Timestamp.now().toDate().toISOString();
        
        await parkRef.update({
          courts: courts,
          updatedAt: admin.firestore.Timestamp.now().toDate().toISOString()
        });
        
        console.log(`Updated court ${courtNumber} player count to ${playerCount}`);
        return { success: true, playerCount };
      } else {
        console.log('Court not found in park:', courtNumber);
        return null;
      }
      
    } catch (error) {
      console.error('Error updating court player count on check-in:', error);
      return { success: false, error: error.message };
    }
  });

/**
 * Cloud Function: Update court player counts when check-ins are updated (checkout)
 * 
 * Triggers: onUpdate for checkins collection
 * Flow:
 * 1. Check if isActive changed from true to false
 * 2. Query active check-ins for that court
 * 3. Update the park document with the current player count
 */
exports.updateCourtPlayerCountOnCheckOut = functions.firestore
  .document('checkins/{checkinId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data();
    const after = change.after.data();
    const db = admin.firestore();
    
    // Only proceed if isActive changed from true to false
    if (before.isActive !== true || after.isActive !== false) {
      return null;
    }
    
    try {
      const parkId = after.parkId;
      const courtNumber = after.courtNumber;
      
      if (!parkId || courtNumber === undefined || courtNumber === null) {
        console.log('Missing parkId or courtNumber in check-in');
        return null;
      }
      
      // Count active check-ins for this court
      const activeCheckIns = await db.collection('checkins')
        .where('parkId', '==', parkId)
        .where('courtNumber', '==', courtNumber)
        .where('isActive', '==', true)
        .get();
      
      const playerCount = activeCheckIns.size;
      console.log(`Court ${courtNumber} at park ${parkId} now has ${playerCount} active check-ins after checkout`);
      
      // Update the park document
      const parkRef = db.collection('parks').doc(parkId);
      const parkDoc = await parkRef.get();
      
      if (!parkDoc.exists) {
        console.log('Park not found:', parkId);
        return null;
      }
      
      const parkData = parkDoc.data();
      const courts = parkData.courts || [];
      
      // Find and update the specific court by courtNumber
      const courtIndex = courts.findIndex(c => c.courtNumber === courtNumber);
      if (courtIndex !== -1) {
        courts[courtIndex].playerCount = playerCount;
        courts[courtIndex].lastUpdated = admin.firestore.Timestamp.now().toDate().toISOString();
        
        await parkRef.update({
          courts: courts,
          updatedAt: admin.firestore.Timestamp.now().toDate().toISOString()
        });
        
        console.log(`Updated court ${courtNumber} player count to ${playerCount} after checkout`);
        return { success: true, playerCount };
      } else {
        console.log('Court not found in park:', courtNumber);
        return null;
      }
      
    } catch (error) {
      console.error('Error updating court player count on checkout:', error);
      return { success: false, error: error.message };
    }
  });

/**
 * Cloud Function: Update court player counts when check-ins are deleted
 * 
 * Triggers: onDelete for checkins collection
 * Flow:
 * 1. Query active check-ins for that court
 * 2. Update the park document with the current player count
 */
exports.updateCourtPlayerCountOnDelete = functions.firestore
  .document('checkins/{checkinId}')
  .onDelete(async (snapshot, context) => {
    const checkin = snapshot.data();
    const db = admin.firestore();
    
    // Only proceed if the check-in was active
    if (!checkin.isActive) {
      return null;
    }
    
    try {
      const parkId = checkin.parkId;
      const courtNumber = checkin.courtNumber;
      
      if (!parkId || courtNumber === undefined || courtNumber === null) {
        console.log('Missing parkId or courtNumber in check-in');
        return null;
      }
      
      // Count active check-ins for this court
      const activeCheckIns = await db.collection('checkins')
        .where('parkId', '==', parkId)
        .where('courtNumber', '==', courtNumber)
        .where('isActive', '==', true)
        .get();
      
      const playerCount = activeCheckIns.size;
      console.log(`Court ${courtNumber} at park ${parkId} now has ${playerCount} active check-ins after deletion`);
      
      // Update the park document
      const parkRef = db.collection('parks').doc(parkId);
      const parkDoc = await parkRef.get();
      
      if (!parkDoc.exists) {
        console.log('Park not found:', parkId);
        return null;
      }
      
      const parkData = parkDoc.data();
      const courts = parkData.courts || [];
      
      // Find and update the specific court by courtNumber
      const courtIndex = courts.findIndex(c => c.courtNumber === courtNumber);
      if (courtIndex !== -1) {
        courts[courtIndex].playerCount = playerCount;
        courts[courtIndex].lastUpdated = admin.firestore.Timestamp.now().toDate().toISOString();
        
        await parkRef.update({
          courts: courts,
          updatedAt: admin.firestore.Timestamp.now().toDate().toISOString()
        });
        
        console.log(`Updated court ${courtNumber} player count to ${playerCount} after deletion`);
        return { success: true, playerCount };
      } else {
        console.log('Court not found in park:', courtNumber);
        return null;
      }
      
    } catch (error) {
      console.error('Error updating court player count on delete:', error);
      return { success: false, error: error.message };
    }
  });

/**
 * Scheduled Function: Lightweight dedupe and post-merge cleanup
 * - Scans a recent window of parks (by createdAt desc)
 * - Groups by rounded lat/lon (~5 decimals ~ 1m)
 * - Chooses a primary (prefer user-submitted over OSM; then oldest)
 * - Marks other docs as duplicates and links their source to primary.altSources
 */
exports.scheduledDedupeParks = functions.pubsub
  .schedule('every 12 hours')
  .timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const nowIso = new Date().toISOString();
    const LIMIT = 1500; // recent window
    const MAX_FIXES = 100; // avoid over-writing in one run

    try {
      const q = await db.collection('parks').orderBy('createdAt', 'desc').limit(LIMIT).get();
      if (q.empty) return null;
      const groups = new Map();
      for (const doc of q.docs) {
        const d = doc.data();
        const lat = Number(d.latitude);
        const lon = Number(d.longitude);
        if (!isFinite(lat) || !isFinite(lon)) continue;
        const key = `${lat.toFixed(5)},${lon.toFixed(5)}`;
        const arr = groups.get(key) || [];
        arr.push({ id: doc.id, data: d });
        groups.set(key, arr);
      }
      let fixes = 0;
      for (const [key, arr] of groups.entries()) {
        if (arr.length < 2) continue;
        // Choose primary: prioritize non-OSM (user-submitted), then earliest createdAt
        arr.sort((a, b) => {
          const aOsm = (a.data.source === 'osm');
          const bOsm = (b.data.source === 'osm');
          if (aOsm !== bOsm) return aOsm ? 1 : -1; // non-OSM first
          const at = a.data.createdAt || '';
          const bt = b.data.createdAt || '';
          return at.localeCompare(bt);
        });
        const primary = arr[0];
        const dups = arr.slice(1);
        if (primary.data.dupOf) continue; // skip if already marked
        const updates = [];
        // Ensure loc index points to primary
        const locRef = db.collection('parkLocIndex').doc('ll:' + key);
        updates.push(locRef.set({ parkId: primary.id, lat: Number(primary.data.latitude), lon: Number(primary.data.longitude), state: primary.data.state || '', registeredAt: nowIso }, { merge: true }));
        // Merge alt sources into primary and mark duplicates
        const altSrcs = [];
        for (const x of dups) {
          if (fixes >= MAX_FIXES) break;
          const src = (x.data.source === 'osm' && x.data.sourceId) ? { type: 'osm', ref: x.data.sourceId } : { type: x.data.source || 'unknown', ref: x.id };
          altSrcs.push(src);
          updates.push(db.collection('parks').doc(x.id).set({ dupOf: primary.id, approved: false, reviewStatus: 'duplicate', updatedAt: nowIso }, { merge: true }));
          fixes += 1;
        }
        if (altSrcs.length) {
          updates.push(db.collection('parks').doc(primary.id).set({ altSources: admin.firestore.FieldValue.arrayUnion(...altSrcs), updatedAt: nowIso }, { merge: true }));
        }
        if (updates.length) await Promise.all(updates);
        if (fixes >= MAX_FIXES) break;
      }
      console.log(`Dedupe scan complete. Fixed ${fixes} duplicate doc(s).`);
      return null;
    } catch (e) {
      console.warn('scheduledDedupeParks error', e);
      return null;
    }
  });
