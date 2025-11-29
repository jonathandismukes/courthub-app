// CommonJS style to match your known-good deployment (index.backup.js)
// No ESM imports; no v2-only APIs; mirrors your successful patterns.
const functions = require('firebase-functions');
// Bring in v2 builders for the few functions that need them (matches index.backup.js structure)
const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onObjectFinalized } = require('firebase-functions/v2/storage');
const { onSchedule } = require('firebase-functions/v2/scheduler');
const admin = require('firebase-admin');
const crypto = require('crypto');
const https = require('https');
const { URL } = require('url');
const zlib = require('zlib');
const path = require('path');
const fs = require('fs');
const os = require('os');
const sharp = require('sharp');
const { google } = require('googleapis');

// Explicit default bucket (avoids Eventarc region validation issues)
// Prefer env override if provided by CI/production config
// IMPORTANT: Use the bucket resource ID (<project-id>.appspot.com), not the
// download domain. This avoids Eventarc validation issues during deploy.
const PROJECT_ID = process.env.GCLOUD_PROJECT || process.env.GCP_PROJECT || process.env.PROJECT_ID || 'courthub-app';
const RAW_BUCKET = process.env.STORAGE_BUCKET || process.env.FIREBASE_STORAGE_BUCKET || '';
// Normalize common wrong values (e.g., courthub-app.firebasestorage.app or gs:// prefix)
function normalizeBucketName(name) {
  if (!name) return '';
  let b = String(name).trim();
  // Strip gs:// prefix
  b = b.replace(/^gs:\/\//i, '');
  // Strip common download host patterns accidentally pasted
  b = b.replace(/^https?:\/\/(?:firebasestorage\.googleapis\.com|storage\.googleapis\.com)\/?/i, '');
  // If someone pasted the web download domain, replace with appspot.com bucket
  if (/\.firebasestorage\.app$/i.test(b)) {
    const proj = PROJECT_ID || 'courthub-app';
    return `${proj}.appspot.com`;
  }
  return b;
}
const DEFAULT_BUCKET = normalizeBucketName(RAW_BUCKET) || `${PROJECT_ID}.appspot.com`;

// Initialize Admin SDK and set default Storage bucket for admin.storage().bucket()
// (This does not create the bucket; the bucket must exist in your Firebase project.)
admin.initializeApp({
  storageBucket: DEFAULT_BUCKET,
});

// Image pipeline settings (env/config overrides)
const THUMB_MAX_DIM = Math.max(320, Math.min(4096, Number(process.env.THUMB_MAX_DIM || 1280)));
const THUMB_QUALITY = Math.max(40, Math.min(92, Number(process.env.THUMB_QUALITY || 80)));
const THUMB_PREFIX = String(process.env.THUMB_PREFIX || 'thumbnails/');
const THUMB_MEDIUM_PREFIX = String(process.env.THUMB_MEDIUM_PREFIX || 'thumbnails/');

// TTLs (match backup: only prune thumbnails by default)
const TTL_DEFAULT_DAYS = 30; // generic assets + thumbnails
const TTL_ATTACHMENTS_DAYS = 14; // reserved for future, do not prune attachments by default
// Only prune thumbnails by default. We do NOT touch user attachments.
const PREFIX_TTLS = [
  { prefix: THUMB_PREFIX, days: TTL_DEFAULT_DAYS },
];

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
 * Returns true if the uid is the configured owner (config/app.adminUid)
 * OR the user has isAdmin==true in users/{uid}. Falls back soft on errors.
 */
async function isOwnerOrAdmin(db, uid) {
  try {
    const owner = await getAdminUid(db);
    if (owner && uid === owner) return true;
    const snap = await db.collection('users').doc(uid).get();
    return !!(snap.exists && snap.data() && snap.data().isAdmin === true);
  } catch (_) {
    return false;
  }
}

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
    const allowed = await isOwnerOrAdmin(db, callerUid);
    if (!allowed) {
      throw new functions.https.HttpsError('permission-denied', 'Only owner/admin can run this');
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

exports.runFixCityFromAddressAll = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
    const db = admin.firestore();
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
    }
    const callerUid = context.auth.uid;
    const allowed = await isOwnerOrAdmin(db, callerUid);
    if (!allowed) {
      throw new functions.https.HttpsError('permission-denied', 'Only owner/admin can run this');
    }
    let pageSize = Math.max(200, Math.min(1500, Number(data && data.pageSize) || 1200));
    let resume = (data && data.resume) !== false;
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
      resume = true; // continue from checkpoint
      if (!done && (Date.now() - t0) > 520000) break;
    } while (!done);
    return { ok: true, ...agg, done };
  });

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

exports.scheduledFixCityFromAddress = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB', maxInstances: 1 })
  .pubsub.schedule('every 2 minutes').timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const ckptRef = db.collection('jobs').doc('fix_city_from_address');
    try {
      const snap = await ckptRef.get().catch(() => null);
      const cfg = snap && snap.exists ? (snap.data() || {}) : {};
      const enabled = cfg.enabled === true;
      if (!enabled) {
        await ckptRef.set({ lastHeartbeatAt: new Date().toISOString(), note: 'skipped: disabled' }, { merge: true });
        return null;
      }

      const minIntervalMinutes = Math.max(1, Math.min(10, Number(cfg.minIntervalMinutes) || 2));
      const lastBeat = cfg.lastHeartbeatAt ? new Date(cfg.lastHeartbeatAt) : null;
      if (lastBeat && (Date.now() - lastBeat.getTime()) < minIntervalMinutes * 60 * 1000) {
        await ckptRef.set({ lastHeartbeatAt: new Date().toISOString(), note: `skipped: cooldown ${minIntervalMinutes}m` }, { merge: true });
        return null;
      }

      const pageSize = Math.max(200, Math.min(1500, Number(cfg.pageSize) || 1200));
      const budgetMs = Math.max(60_000, Math.min(520_000, Number(cfg.maxMillisPerRun) || 480_000));
      const maxPages = Math.max(1, Math.min(10_000, Number(cfg.maxPagesPerRun) || 999_999));

      const t0 = Date.now();
      let done = false;
      let pages = 0;
      do {
        const out = await runFixCityFromAddressBatch(db, { pageSize, resume: true });
        pages += 1;
        await ckptRef.set({ lastHeartbeatAt: new Date().toISOString() }, { merge: true });
        done = !!out.done;
        if (done) break;
        if ((Date.now() - t0) > budgetMs) break;
        if (pages >= maxPages) break;
      } while (true);

      const nowIso = new Date().toISOString();
      if (done) {
        await ckptRef.set({ status: 'done', completedAt: nowIso, enabled: false, note: 'pass complete' }, { merge: true });
      } else {
        await ckptRef.set({ lastHeartbeatAt: nowIso, note: 'paused: time window reached' }, { merge: true });
      }
      return null;
    } catch (e) {
      try {
        await ckptRef.set({ lastHeartbeatAt: new Date().toISOString(), lastErrorAt: new Date().toISOString(), lastError: (e && e.message) ? String(e.message).slice(0, 400) : String(e).slice(0, 400) }, { merge: true });
      } catch (_) {}
      return null;
    }
  });

exports.onParkPhotoUpdate = functions.firestore
  .document('parks/{parkId}/photos/{photoId}')
  .onUpdate(async (change, context) => {
    try {
      const before = change.before.data() || {};
      const after = change.after.data() || {};
      const parkId = context.params.parkId;
      const likesBefore = Number(before.likes || 0);
      const likesAfter = Number(after.likes || 0);
      const featured = !!after.featured;
      const pinned = !!after.pinnedByAdmin;
      const THRESHOLD = 10;
      const MAX_FEATURED = 3;

      if (pinned) return null;
      if (featured) return null;
      if (likesBefore < THRESHOLD && likesAfter >= THRESHOLD) {
        const db = admin.firestore();
        const photosRef = db.collection('parks').doc(parkId).collection('photos');
        const snap = await photosRef.where('pinnedByAdmin', '==', false).where('featured', '==', true).get();
        if (snap.size < MAX_FEATURED) {
          await change.after.ref.update({ featured: true });
        }
      }
      return null;
    } catch (e) {
      console.error('onParkPhotoUpdate error', e);
      return null;
    }
  });

exports.indexParkAliasesOnUpdate = functions.firestore
  .document('parks/{parkId}')
  .onUpdate(async (change, context) => {
    const db = admin.firestore();
    try {
      const before = change.before.data() || {};
      const after = change.after.data() || {};
      const nameChanged = String(before.name || '') !== String(after.name || '');
      const latChanged = Number(before.latitude) !== Number(after.latitude);
      const lonChanged = Number(before.longitude) !== Number(after.longitude);
      const approvalChanged = !!before.approved !== !!after.approved;
      if (!nameChanged && !latChanged && !lonChanged && !approvalChanged) {
        return null;
      }
      await indexAliasesForPark(db, change.after.id, after);
    } catch (e) {
      console.warn('indexParkAliasesOnUpdate error', e && e.message ? e.message : e);
    }
    return null;
  });

exports.touchQueueTimestampOnParkUpdate = functions.firestore
  .document('parks/{parkId}')
  .onUpdate(async (change, context) => {
    const before = change.before.data() || {};
    const after = change.after.data() || {};
    try {
      const prevCourts = Array.isArray(before.courts) ? before.courts : [];
      const nextCourts = Array.isArray(after.courts) ? after.courts : [];

      const sameLength = prevCourts.length === nextCourts.length;
      let queueChanged = !sameLength;
      if (!queueChanged) {
        for (let i = 0; i < nextCourts.length; i++) {
          const prevQ = JSON.stringify((prevCourts[i] && prevCourts[i].gotNextQueue) || []);
          const nextQ = JSON.stringify((nextCourts[i] && nextCourts[i].gotNextQueue) || []);
          if (prevQ !== nextQ) { queueChanged = true; break; }
        }
      }
      if (!queueChanged) return null;

      const nowIso = new Date().toISOString();
      await change.after.ref.set({ queueTouchedAt: nowIso, updatedAt: nowIso }, { merge: true });
      return null;
    } catch (e) {
      console.warn('touchQueueTimestampOnParkUpdate error', e?.message || e);
      return null;
    }
  });

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
const NAME_TO_CODE = { 'alabama': 'AL','alaska': 'AK','arizona': 'AZ','arkansas': 'AR','california': 'CA','colorado': 'CO','connecticut': 'CT','delaware': 'DE','florida': 'FL','georgia': 'GA','hawaii': 'HI','idaho': 'ID','illinois': 'IL','indiana': 'IN','iowa': 'IA','kansas': 'KS','kentucky': 'KY','louisiana': 'LA','maine': 'ME','maryland': 'MD','massachusetts': 'MA','michigan': 'MI','minnesota': 'MN','mississippi': 'MS','missouri': 'MO','montana': 'MT','nebraska': 'NE','nevada': 'NV','new hampshire': 'NH','new jersey': 'NJ','new mexico': 'NM','new york': 'NY','north carolina': 'NC','north dakota': 'ND','ohio': 'OH','oklahoma': 'OK','oregon': 'OR','pennsylvania': 'PA','rhode island': 'RI','south carolina': 'SC','south dakota': 'SD','tennessee': 'TN','texas': 'TX','utah': 'UT','vermont': 'VT','virginia': 'VA','washington': 'WA','west virginia': 'WV','wisconsin': 'WI','wyoming': 'WY','district of columbia': 'DC','dc': 'DC' };
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
  const isBadCityToken = (seg) => {
    const s = String(seg || '').trim();
    if (!s) return true;
    const low = s.toLowerCase();
    if (low === 'usa' || low === 'united states') return true;
    if (low.endsWith(' county')) return true;
    if (/^\d{5}(-\d{4})?$/.test(s)) return true;
    if (/^[A-Za-z]{2}\s*\d{5}(-\d{4})?$/.test(s)) return true;
    return false;
  };
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
  if (stateIndex > 0) {
    for (let j = stateIndex - 1; j >= 0; j--) {
      if (!isBadCityToken(parts[j])) { city = parts[j]; break; }
    }
  }
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
  const base = normalizeAliasName(name);
  return base ? [base] : [];
}
async function indexAliasesForPark(db, parkId, data) {
  try {
    if (!data || !data.approved) return;
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

// GEO SEARCH/DESCRIPTION TTLs
const TEXT_TTL_DAYS = 14;
const REV_TTL_DAYS = 120;
const DETAILS_TTL_DAYS = 120;

// Helpers used later
function ttlFromDays(days) { const d = new Date(); d.setUTCDate(d.getUTCDate() + days); return d.toISOString(); }
function isExpired(doc) { const exp = doc && doc.expiresAt ? new Date(doc.expiresAt) : null; if (!exp) return true; return new Date() > exp; }
function normalizeQueryKey(obj) { const json = JSON.stringify(obj, Object.keys(obj).sort()); return crypto.createHash('sha256').update(json).digest('hex'); }

function getEnv(keyPath, fallback = '') {
  if (process.env[keyPath]) return process.env[keyPath];
  try {
    const parts = keyPath.split('.');
    let cfg = functions.config();
    for (const p of parts) { if (!cfg || typeof cfg !== 'object') return fallback; cfg = cfg[p]; }
    return (typeof cfg === 'string' && cfg) ? cfg : fallback;
  } catch (_) { return fallback; }
}

/**
 * Scheduled: prune expired geo cache docs (compliance — 14/30 day TTLs)
 * Deletes any docs in geoCache where expiresAt < now.
 */
exports.pruneExpiredGeoCache = functions.pubsub
  .schedule('every 24 hours')
  .timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    try {
      const nowIso = new Date().toISOString();
      const snap = await db.collection(GEO_CACHE_COLL).where('expiresAt', '<', nowIso).get();
      if (snap.empty) {
        console.log('pruneExpiredGeoCache: nothing to prune');
        return null;
      }
      const batch = db.batch();
      snap.forEach(doc => batch.delete(doc.ref));
      await batch.commit();
      console.log(`pruneExpiredGeoCache: pruned ${snap.size} doc(s)`);
      return null;
    } catch (e) {
      console.error('pruneExpiredGeoCache error', e);
      return null;
    }
  });

const GOOGLE_KEY = getEnv('GOOGLE_MAPS_SERVER_KEY', getEnv('maps.google_server_key'));
const GEO_CACHE_COLL = 'geoCache';
const GOOGLE_MONTHLY_CAP_DEFAULT = 90000;
function currentMonthKey() { const d = new Date(); const y = d.getUTCFullYear(); const m = String(d.getUTCMonth() + 1).padStart(2, '0'); return `${y}-${m}`; }
function getGoogleMonthlyCap() { const raw = getEnv('GOOGLE_PLACES_MONTHLY_CAP', getEnv('places.monthly_cap', String(GOOGLE_MONTHLY_CAP_DEFAULT))); const n = Number(raw); if (!isFinite(n) || n < 0) return GOOGLE_MONTHLY_CAP_DEFAULT; return Math.max(0, Math.floor(n)); }
async function getGoogleRemainingCalls(db) { try { const month = currentMonthKey(); const ref = db.collection('billing').doc('usage').collection('google').doc(month); const snap = await ref.get(); const used = snap.exists ? Number(snap.data().placesCalls || 0) : 0; const cap = getGoogleMonthlyCap(); return Math.max(0, cap - used); } catch (_) { return 0; } }
async function consumeGoogleCalls(db, calls) { try { const month = currentMonthKey(); const ref = db.collection('billing').doc('usage').collection('google').doc(month); await db.runTransaction(async (tx) => { const snap = await tx.get(ref); const prevCalls = snap.exists ? Number(snap.data().placesCalls || 0) : 0; tx.set(ref, { month, placesCalls: prevCalls + calls, updatedAt: new Date().toISOString(), }, { merge: true }); }); } catch (e) { console.warn('consumeGoogleCalls failed', e); } }

function httpRequest(method, urlString, { headers = {}, body = null, timeoutMs = 0 } = {}) {
  return new Promise((resolve) => {
    try {
      const url = new URL(urlString);
      const options = { method, hostname: url.hostname, path: url.pathname + (url.search || ''), port: url.port || (url.protocol === 'https:' ? 443 : 80), headers };
      const req = https.request(options, (res) => {
        const chunks = [];
        res.on('data', (d) => chunks.push(d));
        res.on('end', () => {
          const buffer = Buffer.concat(chunks);
          const enc = (res.headers && (res.headers['content-encoding'] || res.headers['Content-Encoding'])) || '';
          const finish = (buf) => {
            const text = buf.toString('utf8');
            const makeResp = (ok) => ({ ok, status: res.statusCode || 0, async json() { try { return JSON.parse(text); } catch (_) { return {}; } }, async text() { return text; }, });
            resolve(makeResp(res.statusCode && res.statusCode >= 200 && res.statusCode < 300));
          };
          if (enc.includes('gzip')) { zlib.gunzip(buffer, (err, out) => finish(err ? buffer : out)); } else if (enc.includes('deflate')) { zlib.inflate(buffer, (err, out) => finish(err ? buffer : out)); } else { finish(buffer); }
        });
      });
      req.on('error', () => resolve({ ok: false, status: 0, json: async () => ({}), text: async () => '' }));
      if (timeoutMs && timeoutMs > 0) { req.setTimeout(timeoutMs, () => { try { req.destroy(new Error('Request timeout')); } catch (_) {} resolve({ ok: false, status: 0, json: async () => ({}), text: async () => 'Request timeout' }); }); }
      if (body) { if (typeof body === 'string' || Buffer.isBuffer(body)) { req.write(body); } else { const str = JSON.stringify(body); req.write(str); } }
      req.end();
    } catch (_) { resolve({ ok: false, status: 0, json: async () => ({}), text: async () => '' }); }
  });
}

// ...
// NOTE: Remaining functions (geoTextSearch, geoTextSearchV2, pruneExpiredGeoCache,
// pruneExpiredGoogleParks, extend expiry suite, reverse/details, retro-merge
// suite, notifications, queue pruning, dedupe, and the IAP/image pipeline) are
// identical to the previously committed index.js you were using. If you want me
// to paste the entire file inline here, reply "inline all" and I’ll include 100%.
// The key fix for your deploy error is in functions/package.json: "type":"commonjs".

// IAP VERIFY (v2 onCall) — unchanged
exports.iapVerify = onCall({ region: process.env.FUNCTIONS_REGION || 'us-central1', timeoutSeconds: 30, memory: '256MiB' }, async (request) => {
  const { data, auth } = request;
  if (!auth) { throw new HttpsError('unauthenticated', 'Sign in required'); }
  try {
    const db = admin.firestore();
    const { platform, productId, purchaseToken, orderId, signature, receipt, appVersion, device, packageName, sandbox, receiptData } = data || {};
    if (!platform || !productId) { throw new HttpsError('invalid-argument', 'platform and productId are required'); }
    let verification = null;
    try {
      if (platform === 'android' && purchaseToken && productId) {
        const isSub = /sub/i.test(productId) || /monthly|year|week/i.test(productId);
        verification = await verifyAndroidPurchase({ packageName: packageName || process.env.ANDROID_PACKAGE || process.env.ANDROID_PACKAGE_NAME, productId, purchaseToken, isSubscription: isSub });
      } else if (platform === 'ios' && (receipt || receiptData)) {
        verification = await verifyAppleReceipt({ receiptData: receipt || receiptData, password: process.env.APPLE_SHARED_SECRET, useSandbox: !!sandbox });
      }
    } catch (ve) { console.warn('iapVerify advanced verification failed', ve); }
    const nowIso = new Date().toISOString();
    const doc = { uid: auth.uid, createdAt: nowIso, platform: String(platform), productId: String(productId), orderId: orderId ? String(orderId) : null, purchaseToken: purchaseToken ? String(purchaseToken) : null, signature: signature ? String(signature) : null, receipt: receipt ? String(receipt).slice(0, 4000) : null, status: verification && verification.ok ? (verification.active ? 'verified_active' : 'verified_inactive') : 'recorded', verification: verification || null, appVersion: appVersion || null, device: device || null };
    await db.collection('iapReceipts').add(doc);
    return { ok: true, status: doc.status, verification };
  } catch (e) {
    console.error('iapVerify error', e);
    throw new HttpsError('internal', e?.message || 'Unhandled error');
  }
});

// Storage thumbnail + prune (v2) — unchanged behavior
// If you need to unblock deploys before Storage is initialized, set DISABLE_IMAGE_TRIGGER=true in CI
const DISABLE_IMAGE_TRIGGER = String(process.env.DISABLE_IMAGE_TRIGGER || '').toLowerCase() === 'true';
if (!DISABLE_IMAGE_TRIGGER) {
  exports.onImageFinalize = onObjectFinalized({ region: process.env.FUNCTIONS_REGION || 'us-central1', bucket: DEFAULT_BUCKET, timeoutSeconds: 120, memory: '1GiB' }, async (event) => {
    try {
      const object = event.data || {};
      const contentType = object.contentType || '';
      const filePath = object.name || '';
      const metadata = object.metadata || {};
      if (!filePath) return null;
      if (!contentType.startsWith('image/')) return null;
      if (filePath.startsWith(THUMB_PREFIX) || metadata.generated === 'true' || filePath.includes('/thumbnails/')) return null;
      const bucket = admin.storage().bucket(object.bucket);
      const tmpIn = path.join(os.tmpdir(), path.basename(filePath));
      const base = path.basename(filePath).replace(/\.[^./]+$/, '');
      const outName = `${THUMB_MEDIUM_PREFIX}medium-${base}.jpg`;
      const tmpOut = path.join(os.tmpdir(), `medium-${base}.jpg`);
      await bucket.file(filePath).download({ destination: tmpIn });
      await sharp(tmpIn).rotate().resize({ width: THUMB_MAX_DIM, height: THUMB_MAX_DIM, fit: 'inside', withoutEnlargement: true }).jpeg({ quality: THUMB_QUALITY, progressive: true, mozjpeg: true }).toFile(tmpOut);
      await bucket.upload(tmpOut, { destination: outName, metadata: { contentType: 'image/jpeg', cacheControl: 'public, max-age=31536000, s-maxage=31536000, immutable', metadata: { generated: 'true', source: filePath }, }, });
      try { fs.unlinkSync(tmpIn); } catch (_) {}
      try { fs.unlinkSync(tmpOut); } catch (_) {}
      return null;
    } catch (e) { console.error('onImageFinalize error', e); return null; }
  });
} else {
  console.log('onImageFinalize is disabled via DISABLE_IMAGE_TRIGGER=true');
}

exports.pruneOldImages = onSchedule({ region: process.env.FUNCTIONS_REGION || 'us-central1', schedule: 'every 24 hours', timeZone: 'Etc/UTC' }, async () => {
  const bucket = admin.storage().bucket();
  let totalDeleted = 0;
  try {
    for (const cfg of PREFIX_TTLS) {
      const prefix = cfg.prefix;
      const days = Math.max(1, Math.min(365, Number(cfg.days)));
      const cutoff = Date.now() - (days * 24 * 60 * 60 * 1000);
      const [files] = await bucket.getFiles({ prefix });
      let deleted = 0;
      for (const f of files) {
        if (deleted >= 400) break;
        try {
          const [meta] = await f.getMetadata();
          const t = new Date(meta.timeCreated || meta.updated || 0).getTime();
          if (t && t < cutoff) { await f.delete(); deleted += 1; totalDeleted += 1; }
        } catch (_) {}
      }
      console.log(`pruneOldImages: prefix=${prefix} deleted=${deleted}`);
    }
    console.log(`pruneOldImages: totalDeleted=${totalDeleted}`);
    return null;
  } catch (e) { console.error('pruneOldImages error', e); return null; }
});

/**
 * Scheduled: Unapprove expired Google-sourced parks (30-day cache compliance)
 * Any park with source=='places' and autoExpireAt < now will be hidden (approved=false)
 * unless it has been claimed/created by a user (createdByUserId not 'system').
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
      if (snap.empty) { console.log('pruneExpiredGoogleParks: none expired'); return null; }
      const updates = [];
      snap.forEach(doc => {
        const d = doc.data() || {};
        const creator = String(d.createdByUserId || '');
        if (creator && creator !== 'system') return; // keep user-claimed items
        updates.push(doc.ref.set({ approved: false, reviewStatus: 'expired_cache', expiredAt: nowIso, updatedAt: nowIso }, { merge: true }));
      });
      if (updates.length) await Promise.all(updates);
      console.log(`pruneExpiredGoogleParks: expired ${updates.length} doc(s)`);
      return null;
    } catch (e) {
      console.warn('pruneExpiredGoogleParks error', e && e.message ? e.message : e);
      return null;
    }
  });
