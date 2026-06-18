'use strict';

const AnyList = require('anylist');

let instance = null;
let loggedIn = false;
let loginInProgress = null;

/**
 * Maps AnyList categoryMatchId values to display emoji.
 * Unknown / custom categories fall back to DEFAULT_EMOJI.
 */
const DEFAULT_EMOJI = '🛒';
const CATEGORY_EMOJI = {
  'produce':                              '🥦',
  'dairy':                                '🥛',
  'meat-seafood':                         '🥩',
  'bakery-bread':                         '🍞',
  'beverages':                            '☕',
  'soups-and-canned-goods':               '🥫',
  'condiments-oils-and-salad-dressings':  '🫙',
  'cooking-and-baking':                   '🧑‍🍳',
  'health-and-personal-care':             '💊',
  'household':                            '🏠',
  'home':                                 '🏠',
  'frozen-foods':                         '🧊',
  'snacks':                               '🍿',
  'breakfast-foods':                      '🥐',
  'garden':                               '🌱',
  'pet-supplies':                         '🐾',
  'wine-spirits':                         '🍷',
  'baby':                                 '👶',
  'deli':                                 '🧀',
  'seafood':                              '🐟',
  'floral':                               '💐',
  'international-foods':                  '🌍',
  'organic':                              '🌿',
};

/**
 * Returns the categoryMatchId for an item, with fallbacks for older package versions.
 */
function getCategoryId (item) {
  if (item.categoryMatchId) return item.categoryMatchId;
  if (item.categoryDetails && item.categoryDetails.id) return item.categoryDetails.id;
  return null;
}

/**
 * Formats a hyphenated category ID into a title-case display name.
 * e.g. "soups-and-canned-goods" -> "Soups and Canned Goods"
 */
function formatCategoryName (id) {
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
  if (instance) {
    try { instance.teardown(); } catch (_) {}
  }
  instance = new AnyList({ email, password });
  await instance.login();
  loggedIn = true;
  console.log('[anylist] Authenticated successfully');
}

async function login () {
  if (loginInProgress) return loginInProgress;
  loginInProgress = doLogin().finally(() => { loginInProgress = null; });
  return loginInProgress;
}

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

  const unchecked = (rawList.items || []).filter(item => !item.checked);

  const categoryMap = new Map();
  for (const item of unchecked) {
    const id = getCategoryId(item) || 'other';
    if (!categoryMap.has(id)) categoryMap.set(id, []);
    categoryMap.get(id).push({
      name: item.name || '',
      quantity: item.quantity || '',
      details: item.note || ''
    });
  }

  const categories = Array.from(categoryMap.entries())
    .map(([id, items]) => ({
      name: formatCategoryName(id),
      emoji: CATEGORY_EMOJI[id] || DEFAULT_EMOJI,
      items
    }))
    .sort((a, b) => {
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
