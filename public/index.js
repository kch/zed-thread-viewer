let allTitles = [];
let currentSelectedId = null;
let contentCache = new Map();
let loadingIds = new Set();

// Global function for JSON block expansion - must be defined early
window.toggleBlock = function(blockId) {
  const preview = document.getElementById(blockId + '_preview');
  const full = document.getElementById(blockId + '_full');
  const btn = document.getElementById(blockId + '_btn');

  const isExpanded = full.style.display === 'block';

  if (isExpanded) {
    preview.style.display = 'block';
    full.style.display = 'none';
    btn.textContent = 'show more';
  } else {
    preview.style.display = 'none';
    full.style.display = 'block';
    btn.textContent = 'collapse';
  }
};

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

  // Hide all current content frames
  container.querySelectorAll('.content-frame').forEach(frame => {
    frame.classList.remove('active');
  });

  // Check if we already have this content cached
  if (contentCache.has(id)) {
    const cachedFrame = contentCache.get(id);

    // Always check if this is still the selected row after cache lookup
    if (getSelectedId() === id) {
      cachedFrame.classList.add('active');
    }
    return;
  }

  // Prevent duplicate loading
  if (loadingIds.has(id)) {

    return;
  }

  loadingIds.add(id);


  // Fetch and create new content frame
  try {
    const response = await fetch(`/content/${id}`);
    const html = await response.text();

    // Check if selection changed while we were fetching
    if (getSelectedId() !== id) {

      loadingIds.delete(id);
      return; // Don't add the frame if selection changed
    }

    const contentFrame = document.createElement('div');
    contentFrame.className = 'content-frame active';
    contentFrame.id = `content-frame-${id}`;
    contentFrame.innerHTML = html;

    container.appendChild(contentFrame);
    contentCache.set(id, contentFrame);


    // Final check - ensure this is still the selected row
    if (getSelectedId() !== id) {
      contentFrame.classList.remove('active');

    }
  } catch (error) {
    console.error('Failed to load content:', error);
    if (getSelectedId() === id) {
      container.innerHTML = '<div class="content-frame active"><div class="content-frame-header">Error loading content</div></div>';
    }
  } finally {
    loadingIds.delete(id);

  }
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
      document.body.classList.add('dragging');

      // Create overlay over iframe container only
      const overlay = document.createElement('div');
      overlay.id = 'drag-overlay';
      overlay.style.cssText = 'position: absolute; top: 0; left: 0; width: 100%; height: 100%; z-index: 9999;';
      document.getElementById('content-container').appendChild(overlay);

      currentSelectedId = row.dataset.id;
      selectRow(parseInt(row.dataset.row));
      loadContent();
    }
  });

  window.addEventListener('mousemove', (e) => {
    if (!isDragging) return;
    const titlesTable = document.getElementById('titles');
    const tableRect = titlesTable.getBoundingClientRect();
    const fixedX = tableRect.left + (tableRect.width / 2);
    const elementUnderMouse = document.elementFromPoint(fixedX, e.clientY);
    const row = elementUnderMouse?.closest('.grid-row');
    if (row && row.dataset.row !== undefined) {
      currentSelectedId = row.dataset.id;
      selectRow(parseInt(row.dataset.row));
      loadContent();
    }
  });

  window.addEventListener('mouseup', () => {
    isDragging = false;
    document.body.classList.remove('dragging');

    // Remove overlay
    const overlay = document.getElementById('drag-overlay');
    if (overlay) {
      overlay.remove();
    }
  });

  // Handle wheel scroll during drag to update selection
  document.getElementById('titles').addEventListener('wheel', (e) => {
    if (!isDragging) return;
    // Use setTimeout to let scroll happen first, then update selection
    setTimeout(() => {
      const titlesTable = document.getElementById('titles');
      const tableRect = titlesTable.getBoundingClientRect();
      const fixedX = tableRect.left + (tableRect.width / 2);
      const elementUnderMouse = document.elementFromPoint(fixedX, e.clientY);
      const row = elementUnderMouse?.closest('.grid-row');
      if (row && row.dataset.row !== undefined) {
        currentSelectedId = row.dataset.id;
        selectRow(parseInt(row.dataset.row));
        loadContent();
      }
    }, 0);
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
        const id = selected.dataset.id;
        copyTitleById(title, id);
      }
    }

    if (e.key === 'r' && document.activeElement === document.querySelector('.table-container')) {
      e.preventDefault();
      runImport();
    }

    if (e.key === 'v' && document.activeElement === document.querySelector('.table-container')) {
      e.preventDefault();
      toggleLayout();
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

// Shared copy functionality that targets by ID
function copyTitleById(title, id) {

  navigator.clipboard.writeText(title).then(() => {
    // Animate copy button in content frame for this ID
    const contentFrame = document.querySelector(`#content-frame-${id}`);

    if (contentFrame) {
      const copyBtn = contentFrame.querySelector('.content-copy-btn');

      if (copyBtn) {
        const original = copyBtn.textContent;
        copyBtn.textContent = 'copied!';
        setTimeout(() => copyBtn.textContent = original, 1000);
      }
    }

    // Animate the table row for this ID
    const tableRow = document.querySelector(`#titles .grid-row[data-id="${id}"]`);

    if (tableRow) {
      tableRow.classList.add('copy-animation');
      setTimeout(() => {
        tableRow.classList.remove('copy-animation');
      }, 800);
    }
  });
}

// Global functions for content frame interactions
window.copyTitle = function(title) {
  // Extract ID from the content frame wrapper
  const wrapper = event.target.closest('.content-frame-wrapper');

  const idElement = wrapper.querySelector('[id^="markdown-view-"], [id^="json-view-"]');

  const id = idElement ? idElement.id.split('-').pop() : null;


  if (id) {
    copyTitleById(title, id);
  }
};

window.toggleView = function(id) {
  const wrapper = event.target.closest('.content-frame-wrapper');
  const currentView = wrapper.dataset.view;

  if (currentView === 'markdown') {
    wrapper.dataset.view = 'json';
  } else {
    wrapper.dataset.view = 'markdown';
  }
};



async function runImport() {
  const btn = document.getElementById('reload-btn');
  btn.disabled = true;
  btn.textContent = '...';
  try {
    await fetch('/import', { method: 'POST' });
    const searchQuery = document.getElementById('search').value.trim();
    if (searchQuery) {
      await searchTitles();
    } else {
      await loadTitles();
    }
  } finally {
    btn.disabled = false;
    btn.textContent = '⟳';
  }
}

function toggleLayout() {
  const container = document.querySelector('.container');
  container.classList.toggle('vertical-layout');
}
