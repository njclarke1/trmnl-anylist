'use strict';

const express = require('express');
const { fetchList } = require('../anylist-client');

const router = express.Router();

const DEFAULT_LIST_NAME = process.env.ANYLIST_LIST_NAME || 'Groceries';

router.get('/list', async (req, res) => {
  const listName = (req.query.name || DEFAULT_LIST_NAME).trim();

  if (!listName) {
    return res.status(400).json({ error: 'List name is required. Pass ?name= or set ANYLIST_LIST_NAME.' });
  }

  try {
    const data = await fetchList(listName);

    if (!data) {
      return res.status(404).json({
        error: `List "${listName}" not found in your AnyList account.`,
        hint: 'Check the list name matches exactly (case-sensitive).'
      });
    }

    return res.json(data);
  } catch (err) {
    console.error('[route /list] Error:', err.message);
    return res.status(502).json({
      error: 'Failed to fetch list from AnyList.',
      detail: err.message
    });
  }
});

module.exports = router;
