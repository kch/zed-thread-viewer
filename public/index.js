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
  const current = document.querySelector('#titles .grid-row.selected');
  current?.classList.remove('selected');

  const visibleRows = document.querySelectorAll('#titles .grid-row');
  if (visibleRows[index]) {
    visibleRows[index].classList.add('selected');
    visibleRows[index].scrollIntoView({ block: 'nearest' });

    // Save selection position
    localStorage.setItem('selectedRowIndex', index);

    // Update global selected ID
    currentSelectedId = visibleRows[index].dataset.id;
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
    const visibleRows = Array.from(document.querySelectorAll('#titles .grid-row'));
    if (visibleRows.length === 0) return;

    const currentSelected = document.querySelector('#titles .grid-row.selected');
    const currentIndex = currentSelected ? visibleRows.indexOf(currentSelected) : -1;

    let newIndex;
    if (currentIndex === -1) {
      // No valid selection, go to first row
      newIndex = 0;
    } else {
      // Navigate from current selection
      if (e.key === 'ArrowDown') {
        newIndex = Math.min(currentIndex + 1, visibleRows.length - 1);
      } else {
        newIndex = Math.max(currentIndex - 1, 0);
      }
    }

    selectRow(newIndex);
    loadContent();
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

    if (e.key === 'c' && document.activeElement === document.querySelector('.table-container')) {
      e.preventDefault();
      const selected = document.querySelector('#titles .grid-row.selected');
      if (selected) {
        const title = selected.querySelector('.col-title').textContent;
        navigator.clipboard.writeText(title);
      }
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
