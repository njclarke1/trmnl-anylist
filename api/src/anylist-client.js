'use strict';

const AnyList = require('anylist');

let instance = null;
let loggedIn = false;
let loginInProgress = null; // Prevents concurrent login attempts

function validateConfig () {
  const email = process.env.ANYLIST_EMAIL;
  const password = process.env.ANYLIST_PASSWORD;
  if (!email || !password) {
    throw new Error('ANYLIST_EMAIL and ANYLIST_PASSWORD environment variables are required');
  }
  return { email, password };
}

async function doLogin () {
  const { email, password } = validateConfig();
  // Tear down existing instance cleanly before replacing it
  if (instance) {
    try { instance.teardown(); } catch (_) {}
  }
  instance = new AnyList({ email, password });
  await instance.login();
  loggedIn = true;
  console.log('[anylist] Authenticated successfully');
}

/**
 * Calls doLogin() but serialises concurrent callers so only one login
 * attempt runs at a time (e.g. if several requests arrive during startup).
 */
async function login () {
  if (loginInProgress) return loginInProgress;
  loginInProgress = doLogin().finally(() => { loginInProgress = null; });
  return loginInProgress;
}

/**
 * Returns the name of the category for an item.
 * Tries multiple field names used by different anylist package versions.
 */
function resolveCategory (item) {
  const id = item.categoryMatchId;
  if (!id) return 'Other';
  const conjunctions = ['and', 'or', 'of', 'the', 'in', 'a', 'an'];
  return id
    .split('-')
    .map((word, i) => {
      if (i > 0 && conjunctions.includes(word)) return word;
      return word.charAt(0).toUpperCase() + word.slice(1);
    })
    .join(' ');
}

/**
 * Fetches a named list, returning the normalised JSON the API route will send.
 * On any error that looks like an auth failure, attempts one silent re-login.
 */
async function fetchList (listName) {
  if (!loggedIn) await login();

  async function attempt () {
    await instance.getLists();
    return instance.getListByName(listName);
  }

  let rawList;
  try {
    rawList = await attempt();
  } catch (err) {
    const isAuthError =
      err.statusCode === 401 ||
      (err.message && /auth|unauthori[sz]ed|login|session/i.test(err.message));

    if (isAuthError) {
      console.warn('[anylist] Auth error — attempting re-login:', err.message);
      loggedIn = false;
      await login();
      rawList = await attempt();
    } else {
      throw err;
    }
  }

  if (!rawList) return null;

  // Filter out checked items, then group by category
  const unchecked = (rawList.items || []).filter(item => !item.checked);

  const categoryMap = new Map();
  for (const item of unchecked) {
    const categoryName = resolveCategory(item);
    if (!categoryMap.has(categoryName)) categoryMap.set(categoryName, []);
    categoryMap.get(categoryName).push({
      name: item.name || '',
      quantity: item.quantity || '',
      details: item.note || ''
    });
  }

  const categories = Array.from(categoryMap.entries())
    .map(([name, items]) => ({ name, items }))
    .sort((a, b) => {
      // Push "Other" to the end; everything else alphabetical
      if (a.name === 'Other') return 1;
      if (b.name === 'Other') return -1;
      return a.name.localeCompare(b.name);
    });

  return {
    list_name: rawList.name || listName,
    item_count: unchecked.length,
    categories,
    updated_at: new Date().toISOString()
  };
}

function isReady () {
  return loggedIn;
}

module.exports = { login, fetchList, isReady };
