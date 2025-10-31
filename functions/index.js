const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

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

// Keys can be provided via:
// - process.env.GOOGLE_MAPS_SERVER_KEY
// - functions config: maps.google_server_key
const GOOGLE_KEY = getEnv('GOOGLE_MAPS_SERVER_KEY', getEnv('maps.google_server_key'));
const GEOAPIFY_KEY = getEnv('GEOAPIFY_KEY', getEnv('maps.geoapify_key'));

const GEO_CACHE_COLL = 'geoCache';
// Search cost guardrails: optionally disable Google fallback entirely
// Read from Firestore config/app.searchDisableGoogleFallback (default true to be cost-safe)
let cachedSearchDisableGoogle = null;
let cachedSearchCfgAt = 0;
const SEARCH_CFG_CACHE_MS = 5 * 60 * 1000; // 5 minutes
const GOOGLE_TEXT_SEARCH_CENTS_PER_CALL = 2; // conservative estimate (~$0.017)

function currentMonthKey() {
  const d = new Date();
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, '0');
  return `${y}-${m}`;
}

async function getGoogleBudgetCapCents(db) {
  try {
    const doc = await db.collection('config').doc('app').get();
    const cap = doc.exists ? Number(doc.data().searchGoogleBudgetCentsCap) : NaN;
    if (!isNaN(cap) && cap >= 0) return cap;
    return 10000; // default $100
  } catch (_) {
    return 10000;
  }
}

async function getGoogleRemainingCalls(db) {
  const capCents = await getGoogleBudgetCapCents(db);
  try {
    const month = currentMonthKey();
    const ref = db.collection('billing').doc('usage').collection('google').doc(month);
    const snap = await ref.get();
    const spent = snap.exists ? Number(snap.data().placesCentsAccrued || 0) : 0;
    const remainingCents = Math.max(0, capCents - spent);
    return Math.floor(remainingCents / GOOGLE_TEXT_SEARCH_CENTS_PER_CALL);
  } catch (_) {
    // On error, assume no remaining
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
      const prevCents = snap.exists ? Number(snap.data().placesCentsAccrued || 0) : 0;
      tx.set(ref, {
        month,
        placesCalls: prevCalls + calls,
        placesCentsAccrued: prevCents + calls * GOOGLE_TEXT_SEARCH_CENTS_PER_CALL,
        updatedAt: new Date().toISOString(),
      }, { merge: true });
    });
  } catch (e) {
    console.warn('consumeGoogleCalls failed', e);
  }
}

async function isGoogleFallbackDisabled(db) {
  const now = Date.now();
  if (cachedSearchDisableGoogle !== null && (now - cachedSearchCfgAt) < SEARCH_CFG_CACHE_MS) {
    return cachedSearchDisableGoogle;
  }
  try {
    const doc = await db.collection('config').doc('app').get();
    const disable = doc.exists ? (doc.data().searchDisableGoogleFallback === true) : true; // default true
    cachedSearchDisableGoogle = !!disable;
    cachedSearchCfgAt = Date.now();
    return cachedSearchDisableGoogle;
  } catch (_) {
    // On error, be conservative: disable fallback
    cachedSearchDisableGoogle = true;
    cachedSearchCfgAt = Date.now();
    return true;
  }
}
const TEXT_TTL_DAYS = 14; // cache text search for 14 days
const REV_TTL_DAYS = 30;  // cache reverse geocode for 30 days

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

function standardizePlacesFromGeoapify(features) {
  if (!Array.isArray(features)) return [];
  return features.map(f => {
    const props = f.properties || {};
    const name = props.name || props.street || 'Unknown';
    const address = props.formatted || [props.housenumber, props.street, props.city, props.state].filter(Boolean).join(' ');
    const lat = props.lat || (f.geometry && f.geometry.coordinates ? f.geometry.coordinates[1] : null);
    const lon = props.lon || (f.geometry && f.geometry.coordinates ? f.geometry.coordinates[0] : null);
    return {
      id: props.place_id || `${name}_${lat},${lon}`,
      displayName: name,
      formattedAddress: address || '',
      location: (lat != null && lon != null) ? { latitude: lat, longitude: lon } : null,
      provider: 'geoapify'
    };
  }).filter(p => p.location);
}

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

async function fetchGeoapifyTextSearch(text, bias) {
  if (!GEOAPIFY_KEY) return null;
  // Use generic places text endpoint; optionally bias by proximity if lat/lng available.
  let url = `https://api.geoapify.com/v2/places?text=${encodeURIComponent(text)}&limit=20&apiKey=${GEOAPIFY_KEY}`;
  if (bias && typeof bias.lng === 'number' && typeof bias.lat === 'number') {
    url += `&bias=proximity:${bias.lng},${bias.lat}`;
  }
  const res = await httpRequest('GET', url);
  if (!res.ok) return null;
  const data = await res.json();
  return standardizePlacesFromGeoapify(Array.isArray(data.features) ? data.features : []);
}

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
  return standardizePlacesFromGoogleV1(data);
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
    const places = standardizePlacesFromGoogleV1(data);
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

    // Try Geoapify first (low-cost), then optionally Google
    let places = [];
    try {
      const gfea = await fetchGeoapifyTextSearch(text, bias);
      if (Array.isArray(gfea) && gfea.length > 0) {
        places = gfea;
      }
    } catch (e) {
      console.warn('Geoapify text search error', e);
    }
    const disableGoogle = await isGoogleFallbackDisabled(db);
    if (places.length === 0 && !disableGoogle) {
      const remaining = await getGoogleRemainingCalls(db);
      if (remaining <= 0) {
        console.log('Google fallback skipped: budget cap reached');
      } else {
      try {
        places = await fetchGoogleTextSearch(text, bias);
        await consumeGoogleCalls(db, 1);
      } catch (e) {
        console.warn('Google text search error', e);
      }
      }
    }

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

    // Geoapify single-page attempt first if key present, then optionally Google paged
    let places = [];
    try {
      const gfea = await fetchGeoapifyTextSearch(text, bias);
      if (Array.isArray(gfea) && gfea.length > 0) {
        places = gfea;
      }
    } catch (e) {
      console.warn('Geoapify text search v2 error', e);
    }
    const disableGoogle = await isGoogleFallbackDisabled(db);
    if (places.length === 0 && !disableGoogle) {
      let remaining = await getGoogleRemainingCalls(db);
      if (remaining <= 0) {
        console.log('Google paged search skipped: budget cap reached');
      } else {
        const allowedPages = Math.max(1, Math.min(maxPages, remaining));
      try {
        const out = await fetchGoogleTextSearchPaged({ text, bias, pageAll, maxPages: allowedPages, pageSize });
        places = out.places || [];
        const pagesUsed = Math.min(allowedPages, Math.ceil((places.length || 1) / pageSize));
        await consumeGoogleCalls(db, pagesUsed);
      } catch (e) {
        console.warn('Google text search v2 error', e);
      }
      }
    }

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
 * Callable: Run a single OSM import tick (same behavior as the scheduler)
 * Only the configured owner (config/app.adminUid) may invoke.
 * Writes status to imports/osm and a per-run entry to imports/osm/logs.
 */
exports.runScheduledOsmTickOnce = functions
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

    try {
      const cfgDoc = await db.collection('config').doc('app').get();
      const cfg = cfgDoc.exists ? cfgDoc.data() : {};
      const cfgNodesOnlyDefault = cfg.autoOsmImportNodesOnly !== false; // default true
      const maxCreates = Math.max(1, Math.min(4000, Number(cfg.autoOsmImportMaxCreates) || 1500));

      const statusRef = db.collection('imports').doc('osm');
      const logsColl = statusRef.collection('logs');
      const statusSnap = await statusRef.get();
      const status = statusSnap.exists ? statusSnap.data() : {};
      let nextIndex = Number(status && status.nextIndex) || 0;
      if (nextIndex < 0 || nextIndex >= WEST_TO_EAST_STATE_ORDER.length) nextIndex = 0;
      const state = WEST_TO_EAST_STATE_ORDER[nextIndex];
      const currentPhase = Math.max(1, Number(status && status.phase) || 1);
      const cycleCount = Math.max(0, Number(status && status.cycleCount) || 0);
      const nodesOnly = currentPhase <= 1 ? true : false;
      const effectiveNodesOnly = cfgNodesOnlyDefault ? nodesOnly : false;

      const result = await runOsmImportBatch({ db, adminUid, state, maxCreates, nodesOnly: effectiveNodesOnly });
      const nowIso = new Date().toISOString();
      const nextIdx = (nextIndex + 1) % WEST_TO_EAST_STATE_ORDER.length;
      const wrapped = nextIdx === 0;
      const nextCycleCount = wrapped ? (cycleCount + 1) : cycleCount;
      const nextPhase = wrapped ? (currentPhase === 1 ? 2 : currentPhase) : currentPhase;

      const updated = {
        state: result.state,
        created: result.created,
        skippedExists: result.skippedExists,
        nodesOnly: effectiveNodesOnly,
        maxCreates,
        more: !!result.more,
        lastRunAt: nowIso,
        lastSuccessAt: nowIso,
        totalCreated: Math.max(0, Number(status.totalCreated || 0)) + Number(result.created || 0),
        nextIndex: nextIdx,
        phase: nextPhase,
        cycleCount: nextCycleCount,
      };
      await statusRef.set(updated, { merge: true });
      const runId = `${nowIso.replace(/[:.]/g, '-')}_${state}_manual`;
      await logsColl.doc(runId).set({
        runId,
        ts: nowIso,
        state,
        nextIndex: updated.nextIndex,
        created: result.created,
        skippedExists: result.skippedExists,
        nodesOnly: effectiveNodesOnly,
        maxCreates,
        more: !!result.more,
        phase: currentPhase,
        cycleCount,
        scanned: true,
        zeroCreated: result.created === 0,
        ok: true,
      });
      return { ok: true, ...updated };
    } catch (e) {
      const nowIso = new Date().toISOString();
      const statusRef = db.collection('imports').doc('osm');
      const logsColl = statusRef.collection('logs');
      await statusRef.set({
        lastRunAt: nowIso,
        lastErrorAt: nowIso,
        lastError: (e && e.message) ? String(e.message).slice(0, 500) : String(e).slice(0, 500),
      }, { merge: true }).catch(() => {});
      const errId = `${nowIso.replace(/[:.]/g, '-')}_manual_error`;
      await logsColl.doc(errId).set({
        runId: errId,
        ts: nowIso,
        ok: false,
        error: (e && e.message) ? String(e.message) : String(e),
      }).catch(() => {});
      throw new functions.https.HttpsError('internal', e?.message || 'Unknown error');
    }
  });

async function fetchGeoapifyReverse(lat, lng) {
  if (!GEOAPIFY_KEY) return null;
  const url = `https://api.geoapify.com/v1/geocode/reverse?lat=${lat}&lon=${lng}&apiKey=${GEOAPIFY_KEY}`;
  const res = await httpRequest('GET', url);
  if (!res.ok) return null;
  const data = await res.json();
  const f = Array.isArray(data.features) && data.features.length ? data.features[0] : null;
  if (!f || !f.properties) return null;
  const p = f.properties;
  const address = p.formatted || [p.housenumber, p.street].filter(Boolean).join(' ');
  return { address: address || '', city: p.city || p.town || p.village || '', state: p.state_code || p.state || '' };
}

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
    try { result = await fetchGeoapifyReverse(lat, lng); } catch (e) { console.warn('Geoapify reverse error', e); }
    const disableGoogle = await isGoogleFallbackDisabled(db);
    if (!result && !disableGoogle) {
      const remaining = await getGoogleRemainingCalls(db);
      if (remaining <= 0) {
        console.log('Google reverse skipped: budget cap reached');
      } else {
        try { result = await fetchGoogleReverse(lat, lng); await consumeGoogleCalls(db, 1); } catch (e) { console.warn('Google reverse error', e); }
      }
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
    const disableGoogle = await isGoogleFallbackDisabled(db);
    let details = null;
    if (!disableGoogle) {
      const remaining = await getGoogleRemainingCalls(db);
      if (remaining <= 0) {
        console.log('Google place details skipped: budget cap reached');
      } else {
        details = await fetchGooglePlaceDetails(placeId);
        await consumeGoogleCalls(db, 1);
      }
    }
    if (!details) {
      // Soft-fail: return a minimal stub so client can proceed without error
      return { id: placeId, displayName: 'Unknown', formattedAddress: '', location: null, provider: 'google' };
    }
    await cacheSet(db, key, details, TEXT_TTL_DAYS);
    return details;
  } catch (e) {
    // Fail soft
    console.error('geoPlaceDetails error (soft-fail)', e);
    return { id: '', displayName: 'Unknown', formattedAddress: '', location: null, provider: 'google' };
  }
});

/**
 * ========================
 * PARKS BACKFILL (server-side)
 * ========================
 * Callable + optional scheduled batch that runs the same logic as the in-app
 * ParkBackfillService but on Cloud Functions, so it can run unattended.
 *
 * Control doc (Firestore): backfill/control
 *  - enabled: boolean (default false)
 *  - mode: 'ultraConservative' | 'balanced' | 'full' (default 'balanced')
 *  - capPerRun: number (default 50000)
 *  - clusterDecimals: number (default 3)
 *  - parseCityStateNoApi: boolean (default true)
 *  - refineNamesCap: number (default 0)
 *  - cursor: last processed documentId (managed by the runner)
 *
 * Status doc: backfill/status
 *  - scanned, updated, noCoords, apiMisses, rgCalls, clustersTouched, pages, lastRunAt, lastSuccessAt, lastError, done, cursor
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
  const parts = String(address || '').split(',').map((s) => s.trim());
  let city = '';
  let state = '';
  for (let i = 0; i < parts.length; i++) {
    const m = parts[i].match(/\b([A-Za-z]{2})\b/);
    if (m) {
      const code = m[1];
      if (isTwoLetterState(code)) {
        state = code.toUpperCase();
        if (i > 0 && !city) city = parts[i - 1];
        break;
      }
    }
  }
  if (!state) {
    for (let i = 0; i < parts.length; i++) {
      const code = NAME_TO_CODE[parts[i].toLowerCase()];
      if (code) {
        state = code;
        if (i > 0 && !city) city = parts[i - 1];
        break;
      }
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
      if (!newAddress || isMissingAddress(newAddress) || !newCity || !newState) {
        if (!clusterGeocoded.has(key) && rgCalls < capPerRun) {
          try {
            rg = await fetchGeoapifyReverse(latitude, longitude);
            if (rg) {
              rgCalls += 1;
              clusterGeocoded.add(key);
              clustersTouched += 1;
              const gotAddr = String(rg.address || '').trim();
              const gotCity = String(rg.city || '').trim();
              const gotState = canonState(String(rg.state || '').trim());
              if (gotAddr || gotCity || gotState) {
                placesCacheAddr.set(key, { addr: gotAddr, city: gotCity, state: gotState });
              }
              if (missingAddr) {
                if (!newAddress || isMissingAddress(newAddress)) newAddress = gotAddr || newAddress;
                if (!newCity) newCity = gotCity;
                if (!newState) newState = gotState;
              }
            } else {
              apiMisses += 1;
            }
          } catch (_) { apiMisses += 1; }
        }
      }
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
      try { rg = await fetchGeoapifyReverse(latitude, longitude); } catch (_) { rg = null; }
      if (!rg) { apiMisses += 1; continue; }
      rgCalls += 1;
      const gotAddr = String(rg.address || '').trim();
      const gotCity = String(rg.city || '').trim();
      const gotState = canonState(String(rg.state || '').trim());
      if (missingAddr) {
        if (!newAddress || isMissingAddress(newAddress)) newAddress = gotAddr || newAddress;
        if (!newCity) newCity = gotCity;
        if (!newState) newState = gotState;
      }
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

/**
 * ========================
 * OSM IMPORT (state-batched)
 * ========================
 * Callable function to import basketball/tennis/pickleball courts from
 * OpenStreetMap (via Overpass API) into Firestore as pending parks.
 *
 * Cost and compliance guardrails:
 * - Only the configured owner (config/app.adminUid) can invoke
 * - Writes to parks with approved=false, reviewStatus='pending'
 * - Stores provenance: source='osm', sourceId, sourceAttribution, license='ODbL'
 * - Idempotent by sourceId: uses doc id osm:<type>:<osmId>
 */

// Primary Overpass endpoint and resilient mirror list
const OVERPASS_URL = 'https://overpass-api.de/api/interpreter';
const OVERPASS_MIRRORS = [
  'https://overpass.kumi.systems/api/interpreter',
  'https://overpass-api.de/api/interpreter',
  'https://z.overpass-api.de/api/interpreter',
  'https://lz4.overpass-api.de/api/interpreter',
  'https://overpass.osm.ch/api/interpreter',
];

function shuffle(arr) {
  for (let i = arr.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

/**
 * Post an Overpass query, rotating through mirrors until one succeeds.
 * Returns an object compatible with httpRequest() plus { endpoint }.
 */
async function overpassPostWithMirrors(query, userAgent = 'Courthub/1.0 (+courthub.app)') {
  const headers = {
    'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
    'Accept': 'application/json',
    'User-Agent': userAgent,
  };
  const body = `data=${encodeURIComponent(query)}`;
  const mirrors = shuffle([...OVERPASS_MIRRORS]);
  const MAX_ATTEMPTS_PER_MIRROR = 2;
  for (const url of mirrors) {
    for (let attempt = 1; attempt <= MAX_ATTEMPTS_PER_MIRROR; attempt++) {
      const res = await httpRequest('POST', url, { headers, body, timeoutMs: 25000 });
      if (res.ok) {
        return { ...res, endpoint: url };
      }
      let text = '';
      try { text = await res.text(); } catch (_) { text = ''; }
      const status = res.status || 0;
      const brief = (text || '').slice(0, 200);
      console.warn(`Overpass failure (mirror=${url}, attempt=${attempt}) status=${status} body=${brief}`);
      if (status === 429 || status === 502 || status === 503 || status === 504) {
        // backoff with jitter to be polite and allow mirror to recover
        await sleep(800 * attempt + Math.floor(Math.random() * 500));
        continue;
      }
      // For other statuses, try next mirror immediately
      break;
    }
  }
  return { ok: false, status: 0, json: async () => ({}), text: async () => 'All Overpass mirrors failed', endpoint: '' };
}

/**
 * Acquire a short-lived lease on a Firestore doc to prevent overlapping runs.
 * If a non-expired lease exists, returns { acquired: false, until, owner }.
 * When acquired, returns { acquired: true, until } and writes owner/expiry.
 */
async function tryAcquireLease(db, ref, { leaseField = 'runLease', owner = '', ttlMs = 6 * 60 * 1000 } = {}) {
  const now = Date.now();
  const leaseKeyOwner = `${leaseField}Owner`;
  const leaseKeyUntil = `${leaseField}ExpiresAt`;
  const untilIso = new Date(now + ttlMs).toISOString();
  try {
    const out = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const data = snap.exists ? snap.data() : {};
      const existingUntil = data && data[leaseKeyUntil] ? new Date(data[leaseKeyUntil]).getTime() : 0;
      if (existingUntil && existingUntil > now) {
        return { acquired: false, until: data[leaseKeyUntil], owner: data[leaseKeyOwner] || '' };
      }
      tx.set(ref, { [leaseKeyOwner]: owner, [leaseKeyUntil]: untilIso, lastLeaseAt: new Date(now).toISOString() }, { merge: true });
      return { acquired: true, until: untilIso };
    });
    return out;
  } catch (e) {
    console.warn('tryAcquireLease error', e);
    // Fail closed: do not run if we could not determine lease
    return { acquired: false, until: null, owner: '' };
  }
}

async function releaseLease(db, ref, { leaseField = 'runLease' } = {}) {
  const leaseKeyOwner = `${leaseField}Owner`;
  const leaseKeyUntil = `${leaseField}ExpiresAt`;
  try {
    await ref.set({ [leaseKeyOwner]: null, [leaseKeyUntil]: new Date(Date.now() - 1000).toISOString() }, { merge: true });
  } catch (e) {
    console.warn('releaseLease error', e);
  }
}

const WEST_TO_EAST_STATE_ORDER = [
  'CA', 'OR', 'WA', // West Coast
  'NV', 'AZ', 'ID', 'UT',
  'NM', 'CO', 'MT', 'WY',
  'ND', 'SD', 'NE', 'KS', 'OK', 'TX',
  'MN', 'IA', 'MO', 'AR', 'LA',
  'WI', 'IL', 'MS', 'MI', 'IN', 'KY', 'TN', 'AL', 'GA', 'FL',
  'OH', 'WV', 'VA', 'NC', 'SC',
  'PA', 'NY', 'MD', 'DE', 'NJ', 'CT', 'RI', 'MA', 'VT', 'NH', 'ME', 'DC'
];

// Map state code to ISO3166-2 identifier used by Overpass area queries
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

function makeOverpassQueryForState(stateCode, sportsRegex = 'basketball|tennis|pickleball', { nodesOnly = false } = {}) {
  const iso = STATE_ISO_MAP[stateCode];
  if (!iso) return null;
  // Query leisure=pitch or leisure=sports_centre with sport tags matching our sports
  // Include nodes, ways, relations; request center for non-nodes
  const parts = [];
  // Coverage-first: include any sport-tagged nodes for our sports
  parts.push(`node["sport"~"${sportsRegex}"](area.searchArea);`);
  // Common tagging schemas on facilities
  parts.push(`node["leisure"="pitch"]["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["leisure"="sports_centre"]["sport"~"${sportsRegex}"](area.searchArea);`);
  // Alt schemas widely used: explicit keys and playgrounds
  parts.push(`node["basketball"="yes"](area.searchArea);`);
  parts.push(`node["playground:basketball"="yes"](area.searchArea);`);
  parts.push(`node["leisure"="recreation_ground"]["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["leisure"="playground"]["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["leisure"="playground"]["name"~"${sportsRegex}",i](area.searchArea);`);
  if (!nodesOnly) {
    // When enabled, also include ways/relations with a sport tag directly
    parts.push(`way["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["sport"~"${sportsRegex}"](area.searchArea);`);
    // And ways/relations tagged as pitches or sports centres
    parts.push(`way["leisure"="pitch"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="pitch"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["leisure"="sports_centre"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="sports_centre"]["sport"~"${sportsRegex}"](area.searchArea);`);
    // Alt schemas for ways/relations
    parts.push(`way["basketball"="yes"](area.searchArea);`);
    parts.push(`relation["basketball"="yes"](area.searchArea);`);
    parts.push(`way["playground:basketball"="yes"](area.searchArea);`);
    parts.push(`relation["playground:basketball"="yes"](area.searchArea);`);
    parts.push(`way["leisure"="recreation_ground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="recreation_ground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["leisure"="playground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="playground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["leisure"="playground"]["name"~"${sportsRegex}",i](area.searchArea);`);
    parts.push(`relation["leisure"="playground"]["name"~"${sportsRegex}",i](area.searchArea);`);
  }
  return `
    [out:json][timeout:120];
    area["ISO3166-2"="${iso}"]->.searchArea;
    (
      ${parts.join('\n      ')}
    );
    out tags center;
  `;
}

// Slimmed version for counts only (smaller payload)
function makeOverpassCountQueryForState(stateCode, sportsRegex = 'basketball|tennis|pickleball', { nodesOnly = false } = {}) {
  const iso = STATE_ISO_MAP[stateCode];
  if (!iso) return null;
  const parts = [];
  parts.push(`node["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["leisure"="pitch"]["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["leisure"="sports_centre"]["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["basketball"="yes"](area.searchArea);`);
  parts.push(`node["playground:basketball"="yes"](area.searchArea);`);
  parts.push(`node["leisure"="recreation_ground"]["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["leisure"="playground"]["sport"~"${sportsRegex}"](area.searchArea);`);
  parts.push(`node["leisure"="playground"]["name"~"${sportsRegex}",i](area.searchArea);`);
  if (!nodesOnly) {
    parts.push(`way["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["leisure"="pitch"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="pitch"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["leisure"="sports_centre"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="sports_centre"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["basketball"="yes"](area.searchArea);`);
    parts.push(`relation["basketball"="yes"](area.searchArea);`);
    parts.push(`way["playground:basketball"="yes"](area.searchArea);`);
    parts.push(`relation["playground:basketball"="yes"](area.searchArea);`);
    parts.push(`way["leisure"="recreation_ground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="recreation_ground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["leisure"="playground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`relation["leisure"="playground"]["sport"~"${sportsRegex}"](area.searchArea);`);
    parts.push(`way["leisure"="playground"]["name"~"${sportsRegex}",i](area.searchArea);`);
    parts.push(`relation["leisure"="playground"]["name"~"${sportsRegex}",i](area.searchArea);`);
  }
  return `
    [out:json][timeout:90];
    area["ISO3166-2"="${iso}"]->.searchArea;
    (
      ${parts.join('\n      ')}
    );
    out ids;
  `;
}

// City/Town discovery within a state for targeted backfill
function makeOverpassCitiesInStateQuery(stateCode) {
  const iso = STATE_ISO_MAP[stateCode];
  if (!iso) return null;
  return `
    [out:json][timeout:60];
    area["ISO3166-2"="${iso}"]->.searchArea;
    (
      node["place"~"city|town"](area.searchArea);
    );
    out tags center;
  `;
}

// City-focused search with expanded patterns, radius in meters
function makeOverpassQueryAroundPoint(lat, lon, radiusMeters, sportsRegex = 'basketball|tennis|pickleball', { nodesOnly = false } = {}) {
  const r = Math.max(1000, Math.min(80000, Math.floor(radiusMeters)));
  const parts = [];
  // Sport-tagged features first
  parts.push(`node(around:${r},${lat},${lon})["sport"~"${sportsRegex}"];`);
  parts.push(`node(around:${r},${lat},${lon})["leisure"="pitch"]["sport"~"${sportsRegex}"];`);
  parts.push(`node(around:${r},${lat},${lon})["leisure"="sports_centre"]["sport"~"${sportsRegex}"];`);
  // Name-based heuristic to catch facilities missing sport tag
  parts.push(`node(around:${r},${lat},${lon})["name"~"${sportsRegex}",i];`);
  if (!nodesOnly) {
    parts.push(`way(around:${r},${lat},${lon})["sport"~"${sportsRegex}"];`);
    parts.push(`relation(around:${r},${lat},${lon})["sport"~"${sportsRegex}"];`);
    parts.push(`way(around:${r},${lat},${lon})["leisure"="pitch"]["sport"~"${sportsRegex}"];`);
    parts.push(`relation(around:${r},${lat},${lon})["leisure"="pitch"]["sport"~"${sportsRegex}"];`);
    parts.push(`way(around:${r},${lat},${lon})["leisure"="sports_centre"]["sport"~"${sportsRegex}"];`);
    parts.push(`relation(around:${r},${lat},${lon})["leisure"="sports_centre"]["sport"~"${sportsRegex}"];`);
    // Name-based for ways/relations as well
    parts.push(`way(around:${r},${lat},${lon})["name"~"${sportsRegex}",i];`);
    parts.push(`relation(around:${r},${lat},${lon})["name"~"${sportsRegex}",i];`);
  }
  return `
    [out:json][timeout:120];
    (
      ${parts.join('\n      ')}
    );
    out tags center;
  `;
}

function inferSportTypeFromTags(tags) {
  const sport = (tags && (tags.sport || tags["sport:1"])) || '';
  const name = (tags && tags.name) || '';
  const s = `${sport} ${name}`.toLowerCase();
  if (s.includes('basket')) return 'basketball';
  if (s.includes('pickle')) return 'pickleballSingles';
  if (s.includes('tennis')) return 'tennisSingles';
  // default to basketball if ambiguous
  return 'basketball';
}

function safeNumber(n, fallback) {
  return (typeof n === 'number' && isFinite(n)) ? n : fallback;
}

exports.getOsmImportOrder = functions.https.onCall(async (data, context) => {
  return { order: WEST_TO_EAST_STATE_ORDER };
});

// Shared import routine reused by state and city queries. Includes lightweight dedupe via geo key.
async function importOverpassElements({ db, adminUid, state, elements, maxCreates }) {
  let created = 0;
  let skippedExists = 0;
  const nowIso = new Date().toISOString();

  for (const el of elements) {
    const type = el.type; // node | way | relation
    const osmId = el.id;
    const tags = el.tags || {};
    const id = `osm:${type}:${osmId}`;

    const lat = safeNumber(el.lat || (el.center && el.center.lat), null);
    const lon = safeNumber(el.lon || (el.center && el.center.lon), null);
    if (lat === null || lon === null) continue;

    const name = (tags.name && String(tags.name).trim()) || `${(tags.sport || 'court')} court`;
    const city = tags['addr:city'] || '';
    const address = [tags['addr:housenumber'], tags['addr:street']].filter(Boolean).join(' ');
    const sportType = inferSportTypeFromTags(tags);

    // If the exact OSM doc already exists, skip
    const docRef = db.collection('parks').doc(id);
    const exists = await docRef.get();
    if (exists.exists) {
      skippedExists += 1;
      continue;
    }

    // Lightweight dedupe: round lat/lon to ~1m-10m precision (5 decimals ~1.1m)
    const locKey = `ll:${lat.toFixed(5)},${lon.toFixed(5)}`;
    const locRef = db.collection('parkLocIndex').doc(locKey);
    const locSnap = await locRef.get();
    if (locSnap.exists) {
      // Another park is already registered at this location; treat as duplicate and attach alt source
      const targetParkId = locSnap.data().parkId;
      if (targetParkId) {
        try {
          await db.collection('parks').doc(targetParkId).set({
            altSources: admin.firestore.FieldValue.arrayUnion({ type: 'osm', ref: `${type}/${osmId}` }),
            updatedAt: nowIso,
          }, { merge: true });
        } catch (_) { /* ignore */ }
      }
      skippedExists += 1;
      continue;
    }

    const court = {
      id: 'c1',
      courtNumber: 1,
      customName: null,
      playerCount: 0,
      sportType: sportType,
      type: 'fullCourt',
      condition: 'good',
      hasLighting: false,
      isHalfCourt: false,
      isIndoor: false,
      surface: tags.surface || null,
      lastUpdated: nowIso,
      conditionNotes: null,
      gotNextQueue: [],
    };

    await docRef.set({
      id: id,
      name: name,
      address: address || '',
      city: city || '',
      state: state,
      latitude: lat,
      longitude: lon,
      courts: [court],
      photoUrls: [],
      amenities: [],
      averageRating: 0.0,
      totalReviews: 0,
      description: null,
      approved: true,
      reviewStatus: 'approved',
      reviewMessage: null,
      createdByUserId: adminUid,
      createdByName: 'OSM Import',
      approvedByUserId: adminUid,
      approvedAt: nowIso,
      reviewedByUserId: adminUid,
      reviewedAt: nowIso,
      createdAt: nowIso,
      updatedAt: nowIso,
      source: 'osm',
      sourceId: `${type}/${osmId}`,
      sourceAttribution: '© OpenStreetMap contributors',
      license: 'ODbL',
    }, { merge: false });

    // Register location key to prevent future dups near-identical coords
    try {
      await locRef.set({ parkId: id, lat, lon, state, registeredAt: nowIso }, { merge: false });
    } catch (_) { /* ignore */ }

    created += 1;
    if (created >= maxCreates) break;
  }

  const more = created >= maxCreates; // heuristic
  return { state, created, skippedExists, more };
}

// Run a single state import batch using the common importer
async function runOsmImportBatch({ db, adminUid, state, maxCreates, nodesOnly }) {
  const query = makeOverpassQueryForState(state, 'basketball|tennis|pickleball', { nodesOnly });
  if (!query) {
    throw new functions.https.HttpsError('invalid-argument', 'Could not build query');
  }
  const res = await overpassPostWithMirrors(query, 'Courthub-Importer/1.0 (+courthub.app)');
  if (!res.ok) {
    const text = await res.text().catch(() => '');
    const endpoint = res.endpoint || OVERPASS_URL;
    const brief = (text || '').slice(0, 200);
    console.warn('Overpass error', res.status, endpoint, brief);
    // Surface richer context to Firestore logs and Cloud Logging
    throw new functions.https.HttpsError(
      'unavailable',
      `Overpass request failed (status=${res.status || 0}) via ${endpoint}: ${brief}`
    );
  }
  const json = await res.json();
  const elements = Array.isArray(json.elements) ? json.elements : [];
  const out = await importOverpassElements({ db, adminUid, state, elements, maxCreates });
  return { ...out, overpassEndpoint: res.endpoint };
}

// Increase resources: CA-sized imports can exceed default 60s timeout
exports.importOsmCourtsByState = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB' })
  .https.onCall(async (data, context) => {
  const db = admin.firestore();
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Authentication required');
  }
  const callerUid = context.auth.uid;
  const adminUid = await getAdminUid(db);
  if (!adminUid || callerUid !== adminUid) {
    throw new functions.https.HttpsError('permission-denied', 'Only the owner can run imports');
  }

  const state = String(data && data.state || '').toUpperCase();
  const maxCreates = Math.max(1, Math.min(4000, Number(data && data.maxCreates) || 2000));
  const nodesOnly = !!(data && data.nodesOnly);
  if (!STATE_ISO_MAP[state]) {
    throw new functions.https.HttpsError('invalid-argument', `Unsupported state code: ${state}`);
  }
  try {
    const result = await runOsmImportBatch({ db, adminUid, state, maxCreates, nodesOnly });
    return result;
  } catch (e) {
    // Surface more actionable error codes/messages to the client
    if (e instanceof functions.https.HttpsError) {
      throw e;
    }
    const message = (e && e.message) ? e.message : String(e);
    console.error('OSM import failed', message);
    throw new functions.https.HttpsError('internal', message || 'Unknown error');
  }
});

/**
 * Scheduled Function: Automatically import OSM courts in small batches, rotating
 * through states West→East. This removes manual clicks for large coverage.
 *
 * Safety switches (Firestore config/app):
 * - autoOsmImportEnabled: boolean (must be true to run)
 * - autoOsmImportNodesOnly: boolean (default true)
 * - autoOsmImportMaxCreates: number (default 1500 per run)
 *
 * Progress is written to imports/osm with fields: { state, created, skippedExists,
 * lastRunAt, nextIndex, nodesOnly, maxCreates, more, phase, cycleCount }
 */
exports.scheduledOsmImportBatch = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB', maxInstances: 1 })
  .pubsub
  .schedule('every 7 minutes')
  .timeZone('Etc/UTC')
  .onRun(async (context) => {
    const db = admin.firestore();
    try {
      const statusRef = db.collection('imports').doc('osm');
      const logsColl = statusRef.collection('logs');
      const adminUid = await getAdminUid(db);

      // Run lease to avoid overlapping runs at 7-min cadence
      const leaseOwner = `main:${context.eventId || Math.random().toString(36).slice(2)}`;
      const lease = await tryAcquireLease(db, statusRef, { leaseField: 'runLease', owner: leaseOwner, ttlMs: 6 * 60 * 1000 });
      if (!lease.acquired) {
        const nowIso = new Date().toISOString();
        console.log('[scheduledOsmImportBatch] skipped: lease held until', lease.until, 'by', lease.owner || 'unknown');
        await statusRef.set({ lastRunAt: nowIso, lastNote: 'skipped: overlapping run', leaseHeldUntil: lease.until || null }, { merge: true }).catch(() => {});
        const runId = `${nowIso.replace(/[:.]/g, '-')}_skipped_overlap`;
        await logsColl.doc(runId).set({ runId, ts: nowIso, ok: true, note: 'skipped overlapping run', leaseUntil: lease.until || null }, { merge: true }).catch(() => {});
        return null;
      }

      // Config gate
      const cfgDoc = await db.collection('config').doc('app').get();
      const cfg = cfgDoc.exists ? cfgDoc.data() : {};
      // Default ON unless explicitly disabled
      const autoEnabled = cfg && cfg.autoOsmImportEnabled !== false;
      if (!autoEnabled) {
        const nowIso = new Date().toISOString();
        console.log('[scheduledOsmImportBatch] disabled by config (config/app.autoOsmImportEnabled=false).');
        await statusRef.set({
          lastRunAt: nowIso,
          lastNote: 'skipped: autoOsmImportEnabled=false',
        }, { merge: true }).catch((e) => console.warn('Failed to write heartbeat (disabled)', e));
        const runId = `${nowIso.replace(/[:.]/g, '-')}_skipped_disabled`;
        await logsColl.doc(runId).set({
          runId,
          ts: nowIso,
          ok: true,
          note: 'auto import disabled',
        }).catch(() => {});
        await releaseLease(db, statusRef, { leaseField: 'runLease' });
        return null;
      }

      const cfgNodesOnlyDefault = cfg.autoOsmImportNodesOnly !== false; // default true
      const maxCreates = Math.max(1, Math.min(4000, Number(cfg.autoOsmImportMaxCreates) || 1500));

      // Read status to know which state is next
      const statusSnap = await statusRef.get();
      const status = statusSnap.exists ? statusSnap.data() : {};
      let nextIndex = Number(status && status.nextIndex) || 0;
      if (nextIndex < 0 || nextIndex >= WEST_TO_EAST_STATE_ORDER.length) nextIndex = 0;
      const state = WEST_TO_EAST_STATE_ORDER[nextIndex];

      // Phase/cycle tracking: start at phase=1 (nodes-only). After first full wrap, move to phase=2 (ways enabled).
      const currentPhase = Math.max(1, Number(status && status.phase) || 1);
      const cycleCount = Math.max(0, Number(status && status.cycleCount) || 0);
      // nodesOnly is true for phase 1, false for phase >=2. Config may force nodesOnly=true globally if desired.
      const nodesOnly = currentPhase <= 1 ? true : false;
      // If config explicitly disables nodesOnly (rare), allow ways even in phase 1.
      const effectiveNodesOnly = cfgNodesOnlyDefault ? nodesOnly : false;

      console.log(`[scheduledOsmImportBatch] start state=${state} index=${nextIndex} nodesOnly=${effectiveNodesOnly} maxCreates=${maxCreates}`);
      // Use a safe fallback owner if none configured
      const ownerForWrite = adminUid || 'system';
      const result = await runOsmImportBatch({ db, adminUid: ownerForWrite, state, maxCreates, nodesOnly: effectiveNodesOnly });

      // Advance pointer only when we likely consumed available elements for this pass
      // We still advance even if result.more is true to spread load; next cycle comes back around.
      const nowIso = new Date().toISOString();
      const nextIdx = (nextIndex + 1) % WEST_TO_EAST_STATE_ORDER.length;
      const wrapped = nextIdx === 0;
      const nextCycleCount = wrapped ? (cycleCount + 1) : cycleCount;
      const nextPhase = wrapped ? (currentPhase === 1 ? 2 : currentPhase) : currentPhase;

      const updated = {
        state: result.state,
        created: result.created,
        skippedExists: result.skippedExists,
        nodesOnly: effectiveNodesOnly,
        maxCreates,
        more: !!result.more,
        lastRunAt: nowIso,
        lastSuccessAt: nowIso,
        totalCreated: Math.max(0, Number(status.totalCreated || 0)) + Number(result.created || 0),
        nextIndex: nextIdx,
        phase: nextPhase,
        cycleCount: nextCycleCount,
        overpassEndpoint: result.overpassEndpoint || OVERPASS_URL,
      };
      await statusRef.set(updated, { merge: true });
      // Per-run log for auditability
      const runId = `${nowIso.replace(/[:.]/g, '-')}_${state}`;
      await logsColl.doc(runId).set({
        runId,
        ts: nowIso,
        state,
        nextIndex: updated.nextIndex,
        created: result.created,
        skippedExists: result.skippedExists,
        nodesOnly: effectiveNodesOnly,
        maxCreates,
        more: !!result.more,
        phase: currentPhase,
        cycleCount,
        scanned: true,
        zeroCreated: result.created === 0,
        ok: true,
        overpassEndpoint: result.overpassEndpoint || OVERPASS_URL,
      }).catch((e) => console.warn('Failed to write import log', e));
      console.log(`[scheduledOsmImportBatch] complete state=${state} created=${result.created} skipped=${result.skippedExists} endpoint=${result.overpassEndpoint || OVERPASS_URL}`);
      try {
        // Notify owner if a state produced no new imports (likely complete for current mode)
        if (result.created === 0) {
          const title = `State complete: ${state}`;
          const body = `OSM importer found 0 new courts for ${state} (nodesOnly=${nodesOnly}).`;
          const data = { type: 'osm_state_complete', state };
          await sendNotificationsToUsers(db, [adminUid], title, body, data);
        }
      } catch (e) {
        console.warn('Failed to send completion notification', e);
      }
      await releaseLease(db, statusRef, { leaseField: 'runLease' });
      return null;
    } catch (e) {
      console.error('[scheduledOsmImportBatch] error', e);
      try {
        // Attempt to write an error log and heartbeat so monitoring surfaces failures
        const db2 = admin.firestore();
        const statusRef = db2.collection('imports').doc('osm');
        const logsColl = statusRef.collection('logs');
        const nowIso = new Date().toISOString();
        await statusRef.set({
          lastRunAt: nowIso,
          lastErrorAt: nowIso,
          lastError: (e && e.message) ? String(e.message).slice(0, 500) : String(e).slice(0, 500),
        }, { merge: true });
        const errId = `${nowIso.replace(/[:.]/g, '-')}_error`;
        await logsColl.doc(errId).set({
          runId: errId,
          ts: nowIso,
          error: (e && e.message) ? String(e.message) : String(e),
          ok: false,
        });
        // Also push a failure alert to the owner if available
        try {
          const adminUid = await getAdminUid(db2);
          if (adminUid) {
            const title = 'Importer failed ❌';
            const body = (e && e.message) ? String(e.message).slice(0, 120) : 'Unknown error';
            const data = { type: 'osm_import_failed' };
            await sendNotificationsToUsers(db2, [adminUid], title, body, data);
          }
        } catch (notifyErr) {
          console.warn('Failed to send failure notification', notifyErr);
        }
      } catch (logErr) {
        console.warn('Failed to write failure log', logErr);
      }
      try {
        const db3 = admin.firestore();
        const statusRef3 = db3.collection('imports').doc('osm');
        await releaseLease(db3, statusRef3, { leaseField: 'runLease' });
      } catch (_) {}
      return null;
    }
  });

/**
 * Phase 3: Audit + Adaptive City Backfill
 * - Audits coverage by state (ourCount vs Overpass count)
 * - Enqueues city-focused backfill tasks for low-coverage states
 */
exports.scheduledOsmAuditAndBacklog = functions.pubsub
  .schedule('every 60 minutes')
  .timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const nowIso = new Date().toISOString();
    const statsColl = db.collection('imports').doc('osm').collection('stats');
    const backlogColl = db.collection('imports').doc('osm').collection('backlog');
    const statusRef = db.collection('imports').doc('osm');
    const backfillQueueColl = statusRef.collection('backfillQueue');

    const queuedStates = new Set();
    const coverageSummaries = [];

    for (const state of WEST_TO_EAST_STATE_ORDER) {
      try {
        // Our current count
        const oursSnap = await db.collection('parks').where('state', '==', state).count().get();
        const ourCount = Number(oursSnap.data().count || 0);

        // Overpass lightweight count
        const countQuery = makeOverpassCountQueryForState(state, 'basketball|tennis|pickleball', { nodesOnly: false });
        const res = await overpassPostWithMirrors(countQuery, 'Courthub-Audit/1.0 (+courthub.app)');
        let osmCount = 0;
        if (res.ok) {
          const json = await res.json();
          const elements = Array.isArray(json.elements) ? json.elements : [];
          osmCount = elements.length;
        }

        const coverage = osmCount > 0 ? Math.min(1, ourCount / osmCount) : (ourCount > 0 ? 1 : 0);
        await statsColl.doc(state).set({ state, ourCount, osmCount, coverage, updatedAt: nowIso }, { merge: true });
        coverageSummaries.push({ state, ourCount, osmCount, coverage });

        // If coverage looks low, queue city backfill for this state
        if (osmCount > 0 && coverage < 0.7) {
          const cityQuery = makeOverpassCitiesInStateQuery(state);
          const cRes = await overpassPostWithMirrors(cityQuery, 'Courthub-Audit/1.0 (+courthub.app)');
          if (cRes.ok) {
            const cJson = await cRes.json();
            const cities = (Array.isArray(cJson.elements) ? cJson.elements : [])
              .map(e => ({
                name: (e.tags && (e.tags.name || e.tags['name:en'])) || 'City',
                pop: Number(e.tags && e.tags.population ? e.tags.population : 0) || 0,
                lat: safeNumber(e.lat || (e.center && e.center.lat), null),
                lon: safeNumber(e.lon || (e.center && e.center.lon), null),
              }))
              .filter(c => c.lat !== null && c.lon !== null);

            cities.sort((a, b) => (b.pop - a.pop));
            const top = cities.slice(0, Math.min(20, cities.length));

            for (const c of top) {
              const radiusKm = c.pop >= 100000 ? 25 : (c.pop >= 20000 ? 12 : 8);
              const backId = `${state}_${String(c.name).replace(/[^A-Za-z0-9]+/g, '_').slice(0, 40)}_${Math.round(c.lat*1000)}_${Math.round(c.lon*1000)}`;
              const docRef = backlogColl.doc(backId);
              const snap = await docRef.get();
              if (!snap.exists) {
                await docRef.set({
                  state, cityName: c.name, lat: c.lat, lon: c.lon,
                  radiusKm, nodesOnly: false, patterns: 'expanded',
                  status: 'pending', createdAt: nowIso, attempts: 0,
                });
              }
            }
            // Mark state as queued for backfill (diagnostics chip reconciliation)
            queuedStates.add(state);
          }
        }
      } catch (e) {
        console.warn('Audit error for state', state, e.message || e);
        await statsColl.doc(state).set({ state, errorAt: nowIso, error: String(e).slice(0, 300) }, { merge: true });
      }
    }
    // Reconcile backfillQueue with current queued states
    try {
      const existing = await backfillQueueColl.get();
      const existingIds = new Set(existing.docs.map(d => d.id));
      const deletes = [];
      existingIds.forEach(id => { if (!queuedStates.has(id)) deletes.push(backfillQueueColl.doc(id).delete()); });
      if (deletes.length) await Promise.all(deletes);
      const upserts = [];
      queuedStates.forEach(st => {
        upserts.push(backfillQueueColl.doc(st).set({ queuedAt: nowIso, reason: 'coverage<0.7' }, { merge: true }));
      });
      if (upserts.length) await Promise.all(upserts);
    } catch (e) { console.warn('Failed to reconcile backfillQueue', e); }

    // Publish top 5 lagging states by coverage for quick diagnostics
    try {
      coverageSummaries.sort((a, b) => (a.coverage - b.coverage) || (a.osmCount - b.osmCount));
      const top5 = coverageSummaries.slice(0, Math.min(5, coverageSummaries.length));
      await statusRef.collection('diagnostics').doc('coverage').set({
        updatedAt: nowIso,
        lagging: top5,
      }, { merge: true });
    } catch (e) { console.warn('Failed to publish coverage diagnostics', e); }

    return null;
  });

// Consume one city backlog task per run and import within radius
exports.scheduledOsmBackfillCityBatch = functions
  .runWith({ timeoutSeconds: 540, memory: '1GB', maxInstances: 1 })
  .pubsub
  .schedule('every 15 minutes')
  .timeZone('Etc/UTC')
  .onRun(async () => {
    const db = admin.firestore();
    const backlogColl = db.collection('imports').doc('osm').collection('backlog');
    const statusRef = db.collection('imports').doc('osm');
    const adminUid = await getAdminUid(db);
    const nowIso = new Date().toISOString();

    try {
      // Run lease for city backfill to avoid overlapping consumption
      const leaseOwner = `city:${Math.random().toString(36).slice(2)}`;
      const lease = await tryAcquireLease(db, statusRef, { leaseField: 'cityLease', owner: leaseOwner, ttlMs: 12 * 60 * 1000 });
      if (!lease.acquired) {
        console.log('[scheduledOsmBackfillCityBatch] skipped: city lease held until', lease.until, 'by', lease.owner || 'unknown');
        await statusRef.set({ lastBackfillAt: nowIso, lastNote: 'skipped city: overlapping run', cityLeaseHeldUntil: lease.until || null }, { merge: true }).catch(() => {});
        return null;
      }

      // Pick the oldest pending task
      const q = await backlogColl.where('status', '==', 'pending').orderBy('createdAt', 'asc').limit(1).get();
      if (q.empty) {
        console.log('[scheduledOsmBackfillCityBatch] no pending backlog tasks');
        return null;
      }
      const taskDoc = q.docs[0];
      const task = taskDoc.data();
      // Mark in-progress
      await taskDoc.ref.set({ status: 'running', startedAt: nowIso, attempts: (Number(task.attempts)||0) + 1 }, { merge: true });

      const radiusM = Math.round((task.radiusKm || 10) * 1000);
      const query = makeOverpassQueryAroundPoint(task.lat, task.lon, radiusM, 'basketball|tennis|pickleball', { nodesOnly: false });
      const res = await overpassPostWithMirrors(query, 'Courthub-CityBackfill/1.0 (+courthub.app)');
      if (!res.ok) {
        const text = await res.text().catch(() => '');
        console.warn('[scheduledOsmBackfillCityBatch] Overpass error', res.status, text.slice(0, 160));
        await taskDoc.ref.set({ status: 'pending', lastErrorAt: nowIso, lastError: text.slice(0, 200) }, { merge: true });
        return null;
      }
      const json = await res.json();
      const elements = Array.isArray(json.elements) ? json.elements : [];

      const ownerForWrite = adminUid || 'system';
      const result = await importOverpassElements({ db, adminUid: ownerForWrite, state: task.state, elements, maxCreates: 2000 });

      await taskDoc.ref.set({ status: 'done', finishedAt: new Date().toISOString(), created: result.created, skippedExists: result.skippedExists }, { merge: true });
      // Write a small log and heartbeat
      await statusRef.set({ lastBackfillAt: nowIso, lastBackfillCity: task.cityName, lastBackfillState: task.state, lastBackfillCreated: result.created }, { merge: true });
      // Also mirror into backfill/meta for the diagnostics chip
      try {
        await statusRef.collection('backfill').doc('meta').set({
          lastCity: task.cityName,
          lastState: task.state,
          lastCreated: result.created,
          lastAt: nowIso,
        }, { merge: true });
      } catch (_) {}
      console.log('[scheduledOsmBackfillCityBatch] complete state=', task.state, 'city=', task.cityName, 'created=', result.created, 'skipped=', result.skippedExists);
      await releaseLease(db, statusRef, { leaseField: 'cityLease' });
      return null;
    } catch (e) {
      console.error('[scheduledOsmBackfillCityBatch] error', e);
      // Best effort: leave task pending for retry
      try { await releaseLease(db, statusRef, { leaseField: 'cityLease' }); } catch (_) {}
      return null;
    }
  });

/**
 * Build per-state and per-city indices for diagnostics (counts and lastUpdated)
 * Runs every 6 hours. Writes to stats/states/<state> and stats/states/<state>/cities/<city>
 */
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
