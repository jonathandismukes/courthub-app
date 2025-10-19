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
 */
const crypto = require('crypto');
const https = require('https');
const { URL } = require('url');

function httpRequest(method, urlString, { headers = {}, body = null } = {}) {
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
          const text = buffer.toString('utf8');
          const makeResp = (ok) => ({
            ok,
            status: res.statusCode || 0,
            async json() {
              try { return JSON.parse(text); } catch (_) { return {}; }
            },
            async text() { return text; },
          });
          resolve(makeResp(res.statusCode && res.statusCode >= 200 && res.statusCode < 300));
        });
      });
      req.on('error', () => resolve({ ok: false, status: 0, json: async () => ({}), text: async () => '' }));
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

const GOOGLE_KEY = getEnv('GOOGLE_MAPS_SERVER_KEY', getEnv('maps.google_server_key'));
const GEOAPIFY_KEY = getEnv('GEOAPIFY_KEY', getEnv('maps.geoapify_key'));

const GEO_CACHE_COLL = 'geoCache';
let cachedSearchDisableGoogle = null;
let cachedSearchCfgAt = 0;
const SEARCH_CFG_CACHE_MS = 5 * 60 * 1000; // 5 minutes
const GOOGLE_TEXT_SEARCH_CENTS_PER_CALL = 2;

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
    return 10000;
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
    const disable = doc.exists ? (doc.data().searchDisableGoogleFallback === true) : true;
    cachedSearchDisableGoogle = !!disable;
    cachedSearchCfgAt = Date.now();
    return cachedSearchDisableGoogle;
  } catch (_) {
    cachedSearchDisableGoogle = true;
    cachedSearchCfgAt = Date.now();
    return true;
  }
}
const TEXT_TTL_DAYS = 14;
const REV_TTL_DAYS = 30;

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
    await ref.set({ payload, createdAt: now, expiresAt: ttlFromDays(ttlDays) }, { merge: true });
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

    const key = 'text:' + normalizeQueryKey({ text, bias });
    const cached = await cacheGet(db, key);
    if (cached && Array.isArray(cached.places)) {
      return cached;
    }

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

// ... continues with the rest of functions identical to your functions/index.js ...
