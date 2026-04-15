/**
 * annotator.js — bbox + polygon canvas annotation tool
 * Expects globals: IMAGE_URL, SAVE_URL, CLASS_LIST, EXISTING
 */
(function () {
  'use strict';

  // ── State ──────────────────────────────────────────────────────────────────
  const canvas     = document.getElementById('ann-canvas');
  const ctx        = canvas.getContext('2d');
  const wrap       = document.getElementById('canvas-wrap');
  const toolBbox   = document.getElementById('tool-bbox');
  const toolPoly   = document.getElementById('tool-polygon');
  const classSel   = document.getElementById('class-select');
  const annList    = document.getElementById('ann-list');
  const annCount   = document.getElementById('ann-count');
  const saveBtn    = document.getElementById('save-btn');
  const polyHint   = document.getElementById('poly-hint');
  const saveStatus = document.getElementById('save-status');

  let tool        = 'bbox';        // 'bbox' | 'polygon'
  let annotations = [];            // array of annotation objects
  let selectedIdx = -1;

  // Bbox drag state
  let dragging    = false;
  let dragStart   = null;          // {x, y} in normalized coords
  let dragCurrent = null;

  // Polygon draw state
  let polyPoints  = [];            // [{x,y}] normalized, in-progress polygon
  let polyMouse   = null;          // current mouse pos for live preview

  // Image display
  let img         = new Image();
  let imgLoaded   = false;
  let imgScale    = 1;             // scale factor: canvas px / image px
  let imgOffX     = 0;            // canvas offset of image top-left
  let imgOffY     = 0;

  // Palette — up to 20 distinct hues
  function classColor(id, alpha) {
    const hue = (id * 37) % 360;
    return alpha != null
      ? `hsla(${hue},70%,55%,${alpha})`
      : `hsl(${hue},70%,55%)`;
  }

  // ── Image loading & sizing ────────────────────────────────────────────────
  img.onload = function () {
    imgLoaded = true;
    resize();
    loadExisting();
    render();
  };
  img.src = IMAGE_URL;

  function resize() {
    const dpr = window.devicePixelRatio || 1;
    const ww  = wrap.clientWidth;
    const wh  = wrap.clientHeight;
    canvas.style.width  = ww + 'px';
    canvas.style.height = wh + 'px';
    canvas.width  = ww * dpr;
    canvas.height = wh * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

    if (imgLoaded) {
      const scaleX = ww / img.naturalWidth;
      const scaleY = wh / img.naturalHeight;
      imgScale = Math.min(scaleX, scaleY);
      imgOffX  = (ww - img.naturalWidth  * imgScale) / 2;
      imgOffY  = (wh - img.naturalHeight * imgScale) / 2;
    }
  }

  window.addEventListener('resize', () => { resize(); render(); });

  // ── Coordinate helpers ────────────────────────────────────────────────────
  function canvasPos(e) {
    const rect = canvas.getBoundingClientRect();
    const clientX = e.touches ? e.touches[0].clientX : e.clientX;
    const clientY = e.touches ? e.touches[0].clientY : e.clientY;
    return {
      x: clientX - rect.left,
      y: clientY - rect.top,
    };
  }

  function toNorm(canvX, canvY) {
    return {
      x: Math.max(0, Math.min(1, (canvX - imgOffX) / (img.naturalWidth  * imgScale))),
      y: Math.max(0, Math.min(1, (canvY - imgOffY) / (img.naturalHeight * imgScale))),
    };
  }

  function toCanv(nx, ny) {
    return {
      x: nx * img.naturalWidth  * imgScale + imgOffX,
      y: ny * img.naturalHeight * imgScale + imgOffY,
    };
  }

  // ── Rendering ─────────────────────────────────────────────────────────────
  function render() {
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    ctx.clearRect(0, 0, w, h);

    if (imgLoaded) {
      ctx.drawImage(img,
        imgOffX, imgOffY,
        img.naturalWidth  * imgScale,
        img.naturalHeight * imgScale
      );
    }

    // Draw saved annotations
    annotations.forEach((ann, i) => {
      const selected = (i === selectedIdx);
      if (ann.type === 'bbox') {
        drawBbox(ann, selected);
      } else if (ann.type === 'polygon') {
        drawPolygon(ann.polygon, ann.class_id, selected, 1);
      }
    });

    // Draw in-progress bbox
    if (dragging && dragStart && dragCurrent) {
      const id   = parseInt(classSel.value) || 0;
      const s    = toCanv(dragStart.x, dragStart.y);
      const e    = toCanv(dragCurrent.x, dragCurrent.y);
      const x    = Math.min(s.x, e.x);
      const y    = Math.min(s.y, e.y);
      const bw   = Math.abs(e.x - s.x);
      const bh   = Math.abs(e.y - s.y);
      const col  = classColor(id);
      ctx.strokeStyle = col;
      ctx.lineWidth   = 2;
      ctx.setLineDash([5, 3]);
      ctx.strokeRect(x, y, bw, bh);
      ctx.setLineDash([]);
      ctx.fillStyle = classColor(id, 0.1);
      ctx.fillRect(x, y, bw, bh);
    }

    // Draw in-progress polygon
    if (polyPoints.length > 0) {
      const id  = parseInt(classSel.value) || 0;
      const col = classColor(id);

      ctx.beginPath();
      const first = toCanv(polyPoints[0].x, polyPoints[0].y);
      ctx.moveTo(first.x, first.y);
      polyPoints.slice(1).forEach(p => {
        const c = toCanv(p.x, p.y);
        ctx.lineTo(c.x, c.y);
      });
      if (polyMouse) ctx.lineTo(polyMouse.x, polyMouse.y);

      ctx.strokeStyle = col;
      ctx.lineWidth   = 2;
      ctx.setLineDash([6, 3]);
      ctx.stroke();
      ctx.setLineDash([]);

      // Vertex dots
      polyPoints.forEach((p, idx) => {
        const c = toCanv(p.x, p.y);
        ctx.beginPath();
        ctx.arc(c.x, c.y, idx === 0 ? 7 : 4, 0, Math.PI * 2);
        ctx.fillStyle = idx === 0 ? col : classColor(id, 0.85);
        ctx.fill();
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 1.5;
        ctx.stroke();
      });
    }
  }

  function drawBbox(ann, selected) {
    const {x, y, w, h} = ann.bbox;
    const tl = toCanv(x, y);
    const br = toCanv(x + w, y + h);
    const bw = br.x - tl.x;
    const bh = br.y - tl.y;
    const col = classColor(ann.class_id);

    ctx.strokeStyle = selected ? '#fff' : col;
    ctx.lineWidth   = selected ? 2.5 : 1.8;
    ctx.strokeRect(tl.x, tl.y, bw, bh);
    ctx.fillStyle = classColor(ann.class_id, selected ? 0.18 : 0.08);
    ctx.fillRect(tl.x, tl.y, bw, bh);

    // Label badge
    const label = CLASS_LIST[ann.class_id] || String(ann.class_id);
    ctx.font = 'bold 11px system-ui, sans-serif';
    const tw = ctx.measureText(label).width;
    const padX = 5, padY = 3, lh = 13;
    ctx.fillStyle = col;
    ctx.fillRect(tl.x, tl.y - lh - padY, tw + padX * 2, lh + padY);
    ctx.fillStyle = '#fff';
    ctx.fillText(label, tl.x + padX, tl.y - padY);
  }

  function drawPolygon(points, classId, selected, opacity) {
    if (!points || points.length < 2) return;
    const col = classColor(classId);

    ctx.beginPath();
    const first = toCanv(points[0].x, points[0].y);
    ctx.moveTo(first.x, first.y);
    points.slice(1).forEach(p => {
      const c = toCanv(p.x, p.y);
      ctx.lineTo(c.x, c.y);
    });
    ctx.closePath();

    ctx.fillStyle   = classColor(classId, selected ? 0.3 : 0.15);
    ctx.fill();
    ctx.strokeStyle = selected ? '#fff' : col;
    ctx.lineWidth   = selected ? 2.5 : 1.8;
    ctx.stroke();

    // Vertex dots for selected
    if (selected) {
      points.forEach(p => {
        const c = toCanv(p.x, p.y);
        ctx.beginPath();
        ctx.arc(c.x, c.y, 4, 0, Math.PI * 2);
        ctx.fillStyle = col;
        ctx.fill();
        ctx.strokeStyle = '#fff';
        ctx.lineWidth = 1.5;
        ctx.stroke();
      });
    }

    // Label near centroid
    const cxAvg = points.reduce((s, p) => s + p.x, 0) / points.length;
    const cyAvg = points.reduce((s, p) => s + p.y, 0) / points.length;
    const cv = toCanv(cxAvg, cyAvg);
    const label = CLASS_LIST[classId] || String(classId);
    ctx.font = 'bold 11px system-ui, sans-serif';
    const tw = ctx.measureText(label).width;
    ctx.fillStyle = col;
    ctx.fillRect(cv.x - tw / 2 - 4, cv.y - 9, tw + 8, 14);
    ctx.fillStyle = '#fff';
    ctx.textAlign = 'center';
    ctx.fillText(label, cv.x, cv.y + 2);
    ctx.textAlign = 'left';
  }

  // ── Annotation list sidebar ───────────────────────────────────────────────
  function updateSidebar() {
    annCount.textContent = `(${annotations.length})`;
    annList.innerHTML = '';
    annotations.forEach((ann, i) => {
      const label = CLASS_LIST[ann.class_id] || ann.class_label || String(ann.class_id);
      const col   = classColor(ann.class_id);

      const item = document.createElement('div');
      item.className = 'ann-item' + (i === selectedIdx ? ' selected' : '');
      item.innerHTML = `
        <span class="ann-dot" style="background:${col}"></span>
        <span class="ann-label">${label}</span>
        <span class="ann-type">${ann.type === 'bbox' ? '▭' : '⬡'}</span>
        <span class="ann-delete" data-idx="${i}" title="Delete">✕</span>
      `;
      item.addEventListener('click', (e) => {
        if (e.target.dataset.idx != null) return;
        selectedIdx = i;
        updateSidebar();
        render();
      });
      item.querySelector('.ann-delete').addEventListener('click', () => {
        annotations.splice(i, 1);
        if (selectedIdx >= annotations.length) selectedIdx = annotations.length - 1;
        updateSidebar();
        render();
      });
      annList.appendChild(item);
    });
  }

  // ── Tool switching ────────────────────────────────────────────────────────
  function setTool(t) {
    tool = t;
    toolBbox.classList.toggle('active', t === 'bbox');
    toolPoly.classList.toggle('active', t === 'polygon');
    cancelPoly();
    render();
  }

  toolBbox.addEventListener('click',   () => setTool('bbox'));
  toolPoly.addEventListener('click',   () => setTool('polygon'));

  // ── Mouse / touch events ──────────────────────────────────────────────────
  canvas.addEventListener('mousedown',  onPointerDown);
  canvas.addEventListener('mousemove',  onPointerMove);
  canvas.addEventListener('mouseup',    onPointerUp);
  canvas.addEventListener('dblclick',   onDblClick);
  canvas.addEventListener('touchstart', e => { e.preventDefault(); onPointerDown(e); }, {passive: false});
  canvas.addEventListener('touchmove',  e => { e.preventDefault(); onPointerMove(e); }, {passive: false});
  canvas.addEventListener('touchend',   e => { e.preventDefault(); onPointerUp(e);   }, {passive: false});

  function onPointerDown(e) {
    if (e.button != null && e.button !== 0) return;
    const cp   = canvasPos(e);
    const norm = toNorm(cp.x, cp.y);

    if (tool === 'bbox') {
      dragging   = true;
      dragStart  = norm;
      dragCurrent = norm;
    } else if (tool === 'polygon') {
      // Check if clicking near first vertex to close
      if (polyPoints.length >= 3) {
        const first = toCanv(polyPoints[0].x, polyPoints[0].y);
        const dist  = Math.hypot(cp.x - first.x, cp.y - first.y);
        if (dist < 12) {
          closePoly();
          return;
        }
      }
      polyPoints.push(norm);
      polyHint.style.display = polyPoints.length >= 3 ? '' : 'none';
      render();
    }
  }

  function onPointerMove(e) {
    const cp = canvasPos(e);
    if (tool === 'bbox' && dragging) {
      dragCurrent = toNorm(cp.x, cp.y);
      render();
    } else if (tool === 'polygon' && polyPoints.length > 0) {
      polyMouse = cp;
      render();
    }
  }

  function onPointerUp(e) {
    if (tool === 'bbox' && dragging) {
      dragging = false;
      if (dragStart && dragCurrent) {
        const x = Math.min(dragStart.x, dragCurrent.x);
        const y = Math.min(dragStart.y, dragCurrent.y);
        const w = Math.abs(dragCurrent.x - dragStart.x);
        const h = Math.abs(dragCurrent.y - dragStart.y);
        if (w > 0.005 && h > 0.005) {
          const classId    = parseInt(classSel.value) || 0;
          const classLabel = CLASS_LIST[classId] || String(classId);
          annotations.push({
            type:        'bbox',
            class_id:    classId,
            class_label: classLabel,
            bbox:        {x, y, w, h},
          });
          selectedIdx = annotations.length - 1;
          updateSidebar();
        }
      }
      dragStart   = null;
      dragCurrent = null;
      render();
    }
  }

  function onDblClick(e) {
    if (tool === 'polygon' && polyPoints.length >= 3) {
      closePoly();
    }
  }

  function closePoly() {
    if (polyPoints.length < 3) { cancelPoly(); return; }
    const classId    = parseInt(classSel.value) || 0;
    const classLabel = CLASS_LIST[classId] || String(classId);
    annotations.push({
      type:        'polygon',
      class_id:    classId,
      class_label: classLabel,
      polygon:     [...polyPoints],
    });
    selectedIdx = annotations.length - 1;
    cancelPoly();
    updateSidebar();
    render();
  }

  function cancelPoly() {
    polyPoints   = [];
    polyMouse    = null;
    polyHint.style.display = 'none';
    render();
  }

  // ── Keyboard shortcuts ────────────────────────────────────────────────────
  document.addEventListener('keydown', e => {
    if (e.target.tagName === 'INPUT' || e.target.tagName === 'SELECT' || e.target.tagName === 'TEXTAREA') return;
    switch (e.key.toLowerCase()) {
      case 'b': setTool('bbox'); break;
      case 'p': setTool('polygon'); break;
      case 'escape': cancelPoly(); break;
      case 'delete':
      case 'backspace':
        if (selectedIdx >= 0 && selectedIdx < annotations.length) {
          annotations.splice(selectedIdx, 1);
          selectedIdx = Math.min(selectedIdx, annotations.length - 1);
          updateSidebar();
          render();
        }
        break;
      case 's':
        if (!e.ctrlKey && !e.metaKey) { e.preventDefault(); saveAnnotations(); }
        break;
    }
  });

  // ── Save ──────────────────────────────────────────────────────────────────
  saveBtn.addEventListener('click', saveAnnotations);

  function saveAnnotations() {
    saveStatus.textContent = 'Saving…';
    saveStatus.style.color = 'var(--text-muted)';

    fetch(SAVE_URL, {
      method:  'POST',
      headers: {'Content-Type': 'application/json'},
      body:    JSON.stringify({annotations}),
    })
    .then(r => r.json())
    .then(d => {
      if (d.status === 'ok') {
        saveStatus.textContent = `Saved ${d.count} annotation(s)`;
        saveStatus.style.color = 'var(--success)';
      } else {
        saveStatus.textContent = 'Error: ' + (d.error || 'unknown');
        saveStatus.style.color = 'var(--danger)';
      }
      setTimeout(() => { saveStatus.textContent = ''; }, 3000);
    })
    .catch(err => {
      saveStatus.textContent = 'Network error';
      saveStatus.style.color = 'var(--danger)';
    });
  }

  // ── Load existing annotations ─────────────────────────────────────────────
  function loadExisting() {
    annotations = (EXISTING || []).map(ann => {
      if (ann.type === 'bbox') {
        return {
          type:        'bbox',
          class_id:    ann.class_id,
          class_label: ann.class_label,
          bbox:        ann.bbox,
        };
      } else {
        return {
          type:        'polygon',
          class_id:    ann.class_id,
          class_label: ann.class_label,
          polygon:     ann.polygon,
        };
      }
    });
    updateSidebar();
  }

  // ── Init ──────────────────────────────────────────────────────────────────
  resize();
})();
