import functions from 'firebase-functions';
import admin from 'firebase-admin';
import { google } from 'googleapis';
import fetch from 'node-fetch';
import sharp from 'sharp';
import os from 'os';
import path from 'path';
import fs from 'fs/promises';

try { admin.initializeApp(); } catch (_) {}
const db = admin.firestore();

// Helpers
const region = 'us-central1';
const ANDROID_PACKAGE = process.env.ANDROID_PACKAGE || 'com.yourcompany.hoopsight';
const APPLE_SHARED_SECRET = process.env.APPLE_SHARED_SECRET || '';
const STORAGE_BUCKET = process.env.FUNCTIONS_EMULATOR ? 'local-bucket' : admin.storage().bucket().name;

// Image pipeline configuration
const IMAGE_PREFIXES = ['parks/', 'reviews/', 'reports/', 'users/', 'groups/attachments/'];
const THUMB_PREFIX = 'thumb_';
const THUMB_MAX = 768; // px, medium thumbnail
const CACHE_ORIGINAL = 'public, max-age=31536000, immutable'; // 365 days
const CACHE_THUMB = 'public, max-age=604800, stale-while-revalidate=86400'; // 7d + 1d SWR

// TTL cleanup configuration
const TTL_DEFAULT_DAYS = 365; // everything except chat attachments
const TTL_ATTACHMENTS_DAYS = 90; // chat attachments shorter TTL
const ATTACHMENTS_PREFIX = 'groups/attachments/';

async function verifyAndroidPurchase({ packageName, productId, token }) {
  const auth = new google.auth.GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/androidpublisher'],
  });
  const client = await auth.getClient();
  const androidpublisher = google.androidpublisher({ version: 'v3', auth: client });

  // Try as one-time product first
  try {
    const res = await androidpublisher.purchases.products.get({
      packageName,
      productId,
      token,
    });
    const data = res.data;
    // purchaseState: 0 purchased, 1 canceled, 2 pending
    const purchased = String(data.purchaseState) === '0';
    return { valid: purchased, kind: 'inapp', data };
  } catch (e) {
    // Fall through to subscription attempt
  }

  // Try as subscription (v2)
  try {
    const res = await androidpublisher.purchases.subscriptionsv2.get({
      packageName,
      token,
    });
    const data = res.data;
    const latest = data?.lineItems?.[0];
    const expiryMillis = Number(latest?.expiryTime) || 0;
    const now = Date.now();
    return { valid: expiryMillis > now, kind: 'sub', data };
  } catch (e) {
    return { valid: false, error: e?.message || String(e) };
  }
}

async function verifyApplePurchase({ receiptData }) {
  if (!APPLE_SHARED_SECRET) {
    return { valid: false, error: 'APPLE_SHARED_SECRET not configured' };
  }
  const body = {
    'receipt-data': receiptData,
    password: APPLE_SHARED_SECRET,
    exclude_old_transactions: true,
  };
  // Try production, then fallback to sandbox
  const prodUrl = 'https://buy.itunes.apple.com/verifyReceipt';
  const sandboxUrl = 'https://sandbox.itunes.apple.com/verifyReceipt';
  let resp = await fetch(prodUrl, { method: 'POST', body: JSON.stringify(body) });
  let json = await resp.json();
  if (json.status === 21007) {
    resp = await fetch(sandboxUrl, { method: 'POST', body: JSON.stringify(body) });
    json = await resp.json();
  }
  const status = json.status;
  // status 0 = valid; others are error
  if (status !== 0) return { valid: false, error: `apple_status_${status}` };
  // Find latest active auto-renewing subscription or non-consumable purchase
  const latest = (json.latest_receipt_info || []).sort((a, b) => Number(b.expires_date_ms || 0) - Number(a.expires_date_ms || 0))[0];
  if (latest) {
    const expires = Number(latest.expires_date_ms || 0);
    const valid = expires === 0 || expires > Date.now();
    return { valid, kind: expires ? 'sub' : 'inapp', data: latest, expiryMs: expires || null };
  }
  // For non-subscription, check in_app entries
  const inapps = json.receipt?.in_app || [];
  const hasInapp = inapps.length > 0;
  return { valid: hasInapp, kind: 'inapp', data: inapps[0] || null };
}

export const iapVerify = functions.region(region).https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be signed in');
  }
  const uid = context.auth.uid;
  const platform = String(data.platform || '');
  const productId = String(data.productId || '');
  const ver = data.verificationData || {};

  try {
    let valid = false;
    let premiumUntil = null;

    if (platform === 'android') {
      const token = String(ver.serverVerificationData || ver.localVerificationData || '').trim();
      if (!token) throw new Error('Missing android token');
      const result = await verifyAndroidPurchase({ packageName: ANDROID_PACKAGE, productId, token });
      valid = !!result.valid;
      if (valid && result.kind === 'sub') {
        // Subscriptions v2 returns expiryTime (ms since epoch) in lineItems
        const expiryMs = Number(result.data?.lineItems?.[0]?.expiryTime || 0);
        if (expiryMs > 0) premiumUntil = new Date(expiryMs).toISOString();
      }
    } else if (platform === 'ios') {
      const receiptData = String(ver.serverVerificationData || ver.localVerificationData || '').trim();
      if (!receiptData) throw new Error('Missing ios receipt data');
      const result = await verifyApplePurchase({ receiptData });
      valid = !!result.valid;
      if (valid && result.kind === 'sub' && result.expiryMs) {
        premiumUntil = new Date(Number(result.expiryMs)).toISOString();
      }
    } else {
      throw new Error('Unsupported platform');
    }

    if (!valid) {
      return { valid: false };
    }

    // Determine tier and write to Firestore
    const updates = { planTier: 'premium', updatedAt: new Date().toISOString() };
    if (premiumUntil) updates['premiumUntil'] = premiumUntil;
    else updates['premiumUntil'] = admin.firestore.FieldValue.delete(); // lifetime

    await db.collection('users').doc(uid).set(updates, { merge: true });

    return { valid: true, planTier: 'premium', premiumUntil: premiumUntil || null };
  } catch (e) {
    console.error('iapVerify failed', e);
    throw new functions.https.HttpsError('internal', String(e?.message || e));
  }
});

// Storage onFinalize: generate medium thumbnail and set Cache-Control headers
export const onImageFinalize = functions.region(region).storage.object().onFinalize(async (object) => {
  try {
    const contentType = object.contentType || '';
    const name = object.name || '';
    const bucketName = object.bucket || STORAGE_BUCKET;

    // Only process images in allowed prefixes
    const isImage = contentType.startsWith('image/');
    const inScope = IMAGE_PREFIXES.some((p) => name.startsWith(p));
    if (!isImage || !inScope) return;

    // Skip already generated thumbnails
    const baseName = path.basename(name);
    if (baseName.startsWith(THUMB_PREFIX)) return;

    const bucket = admin.storage().bucket(bucketName);

    // Ensure Cache-Control on original
    try {
      await bucket.file(name).setMetadata({ cacheControl: CACHE_ORIGINAL });
    } catch (e) {
      console.warn('[onImageFinalize] setMetadata original failed', name, e);
    }

    // Prepare temp paths
    const tempDir = os.tmpdir();
    const tempLocalPath = path.join(tempDir, baseName);
    const thumbName = path.join(path.dirname(name), `${THUMB_PREFIX}${baseName}.jpg`);
    const tempThumbPath = path.join(tempDir, `${THUMB_PREFIX}${baseName}.jpg`);

    // Download original
    await bucket.file(name).download({ destination: tempLocalPath });

    // Generate thumbnail using sharp with EXIF-based rotation
    await sharp(tempLocalPath)
      .rotate()
      .resize({ width: THUMB_MAX, withoutEnlargement: true })
      .jpeg({ quality: 78, mozjpeg: true })
      .toFile(tempThumbPath);

    // Upload thumbnail with Cache-Control
    await bucket.upload(tempThumbPath, {
      destination: thumbName,
      metadata: { contentType: 'image/jpeg', cacheControl: CACHE_THUMB },
    });

    // Cleanup temp files
    await Promise.allSettled([
      fs.unlink(tempLocalPath).catch(() => {}),
      fs.unlink(tempThumbPath).catch(() => {}),
    ]);

    console.log('[onImageFinalize] Generated thumbnail for', name, '->', thumbName);
  } catch (e) {
    console.error('[onImageFinalize] failed', e);
  }
});

// Daily TTL cleanup: delete old images per policy
export const pruneOldImages = functions.region(region).pubsub.schedule('every 24 hours').onRun(async () => {
  const bucket = admin.storage().bucket();
  const now = Date.now();

  // Helper to process a prefix with TTL days
  async function prunePrefix(prefix, ttlDays) {
    const ttlMs = ttlDays * 24 * 60 * 60 * 1000;
    const cutoff = now - ttlMs;
    const [files] = await bucket.getFiles({ prefix });
    let deleted = 0;
    for (const file of files) {
      try {
        const name = file.name;
        const meta = file.metadata || {};
        const createdStr = meta.timeCreated || meta.updated || meta.metagenerationTime || null;
        const createdMs = createdStr ? Date.parse(createdStr) : 0;
        if (!createdMs) continue;
        if (createdMs < cutoff) {
          await file.delete();
          deleted++;
          // If we deleted original, attempt to delete its thumb or vice versa
          const base = path.basename(name);
          if (base.startsWith(THUMB_PREFIX)) {
            const orig = name.replace(`${THUMB_PREFIX}`, '').replace(/\.jpg$/i, '');
            await bucket.file(orig).delete({ ignoreNotFound: true }).catch(() => {});
          } else {
            const thumb = path.join(path.dirname(name), `${THUMB_PREFIX}${base}.jpg`);
            await bucket.file(thumb).delete({ ignoreNotFound: true }).catch(() => {});
          }
        }
      } catch (e) {
        console.warn('[pruneOldImages] failed for', file.name, e);
      }
    }
    console.log(`[pruneOldImages] prefix=${prefix} ttlDays=${ttlDays} deleted=${deleted}`);
  }

  // Run for all prefixes
  await Promise.all([
    // Short TTL for chat attachments
    prunePrefix(ATTACHMENTS_PREFIX, TTL_ATTACHMENTS_DAYS),
    // Default TTL for other image areas
    prunePrefix('parks/', TTL_DEFAULT_DAYS),
    prunePrefix('reviews/', TTL_DEFAULT_DAYS),
    prunePrefix('reports/', TTL_DEFAULT_DAYS),
    prunePrefix('users/', TTL_DEFAULT_DAYS),
  ]);

  return null;
});
