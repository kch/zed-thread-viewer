let allTitles = [];
let currentSelectedId = null;
let iframeCache = new Map();

async function loadTitles() {
  const response = await fetch('/titles');
  allTitles = await response.json();
  displayTitles(allTitles);

  // Restore previous selection or auto-select first item
  const table = document.getElementById('titles');
  const savedSelection = localStorage.getItem('selectedEntryId');
  let selectionRestored = false;

  const rows = table.querySelectorAll('.grid-row');
  if (savedSelection && rows.length > 0) {
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].dataset.id === savedSelection) {
        selectRow(i);
        selectionRestored = true;
        break;
      }
    }
  }

  // If no ID match, try restoring by row index
  if (!selectionRestored) {
    const savedIndex = localStorage.getItem('selectedRowIndex');
    const rows = table.querySelectorAll('.grid-row');
    if (savedIndex && rows[parseInt(savedIndex)]) {
      selectRow(parseInt(savedIndex));
      selectionRestored = true;
    }
  }

  if (!selectionRestored && rows.length > 0) {
    selectRow(0);
  }

  if (rows.length > 0) {
    loadContent();
  }
}

function displayTitles(titles) {
  const table = document.querySelector('#titles');
  const existingRows = table.querySelectorAll('.grid-row');
  const selectedId = getSelectedId();

  existingRows.forEach(row => row.remove());

  titles.forEach((item, index) => {
    const symbol = item.symbol || '';
    const date = item.created_at ? new Date(item.created_at).toISOString().split('T')[0] : '';
    const workspace = item.workspace || '';

    const row = document.createElement('div');
    row.className = `grid-row type-${item.type}`;
    row.dataset.row = index;
    row.dataset.id = item.id;
    row.innerHTML = `
      <div class="grid-cell col-symbol">${symbol}</div>
      <div class="grid-cell col-date">${date}</div>
      <div class="grid-cell col-title">${item.title}</div>
      <div class="grid-cell col-project">${workspace}</div>
    `;
    table.appendChild(row);
  });

  // Restore selection if item still exists
  const idToRestore = selectedId || currentSelectedId;
  if (idToRestore) {
    const rows = table.querySelectorAll('.grid-row');
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].dataset.id === idToRestore) {
        selectRow(i);
        return;
      }
    }
  }
}

function selectRow(index) {
  const table = document.querySelector('#titles');
  const current = table.querySelector('.grid-row.selected');
  current?.classList.remove('selected');

  const rows = table.querySelectorAll('.grid-row');
  if (rows[index]) {
    rows[index].classList.add('selected');
    rows[index].scrollIntoView({ block: 'nearest' });

    // Save selection position
    localStorage.setItem('selectedRowIndex', index);

    // Update global selected ID
    const selectedRow = table.querySelectorAll('.grid-row')[index];
    currentSelectedId = selectedRow ? selectedRow.dataset.id : null;
  }
}

function getSelectedId() {
  const selected = document.querySelector('#titles .grid-row.selected');
  return selected?.dataset.id;
}

async function searchTitles() {
  // Store current selection before search
  if (!currentSelectedId) {
    currentSelectedId = getSelectedId();
  }

  const query = document.getElementById('search').value.trim();
  if (query.length === 0) {
    displayTitles(allTitles);
    return;
  }

  const response = await fetch(`/search?q=${encodeURIComponent(query)}`);
  const results = await response.json();
  displayTitles(results);
}

async function loadContent() {
  const id = getSelectedId();
  if (!id) return;

  localStorage.setItem('selectedEntryId', id);

  const container = document.getElementById('content-container');

  // Hide all current iframes
  container.querySelectorAll('iframe').forEach(iframe => {
    iframe.classList.remove('active');
  });

  // Check if we already have this iframe
  if (iframeCache.has(id)) {
    const cachedIframe = iframeCache.get(id);
    cachedIframe.classList.add('active');
    return;
  }

  // Create new iframe for this content
  const iframe = document.createElement('iframe');
  iframe.id = `content-frame-${id}`;
  iframe.src = `/content/${id}`;
  iframe.title = "Thread content viewer";
  iframe.classList.add('active');

  container.appendChild(iframe);
  iframeCache.set(id, iframe);
}

// Table keyboard navigation
document.addEventListener('DOMContentLoaded', () => {
  document.querySelector('.table-container').addEventListener('keydown', (e) => {
    if (!['ArrowUp', 'ArrowDown'].includes(e.key)) return;

    e.preventDefault();
    const table = document.querySelector('#titles');
    const rows = Array.from(table.querySelectorAll('.grid-row'));
    const current = table.querySelector('.grid-row.selected');
    const index = current ? parseInt(current.dataset.row) : -1;

    let newIndex = e.key === 'ArrowDown'
      ? Math.min(index + 1, rows.length - 1)
      : Math.max(index - 1, 0);

    if (index === -1 && e.key === 'ArrowDown') newIndex = 0;

    currentSelectedId = rows[newIndex] ? rows[newIndex].dataset.id : null;
    selectRow(newIndex);
    loadContent();
  });

  // Auto-select first row when table container receives focus
  document.querySelector('.table-container').addEventListener('focus', (e) => {
    const selected = document.querySelector('#titles .grid-row.selected');
    const table = document.querySelector('#titles');
    if (!selected && table.querySelectorAll('.grid-row').length > 0) {
      selectRow(0);
    }
  });

  // Mouse selection handling
  let isDragging = false;

  document.getElementById('titles').addEventListener('mousedown', (e) => {
    const row = e.target.closest('.grid-row');
    if (row && row.dataset.row !== undefined) {
      isDragging = true;
      currentSelectedId = row.dataset.id;
      selectRow(parseInt(row.dataset.row));
      loadContent();
    }
  });

  document.getElementById('titles').addEventListener('mousemove', (e) => {
    if (!isDragging) return;
    const row = e.target.closest('.grid-row');
    if (row && row.dataset.row !== undefined) {
      currentSelectedId = row.dataset.id;
      selectRow(parseInt(row.dataset.row));
      loadContent();
    }
  });

  document.addEventListener('mouseup', () => {
    isDragging = false;
  });

  // Global keyboard handler for '/' key and input arrow keys
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && document.activeElement !== document.getElementById('search')) {
      e.preventDefault();
      document.getElementById('search').focus();
    }
  });

  // Input arrow key handling
  document.getElementById('search').addEventListener('keydown', (e) => {
    if (['ArrowUp', 'ArrowDown'].includes(e.key)) {
      e.preventDefault();
      const container = document.querySelector('.table-container');
      container.focus();

      // Simulate the arrow key on the table container
      const event = new KeyboardEvent('keydown', {
        key: e.key,
        bubbles: true,
        cancelable: true
      });
      container.dispatchEvent(event);
    }
  });

  // Focus search input on load
  document.getElementById('search').focus();

  loadTitles();
});
