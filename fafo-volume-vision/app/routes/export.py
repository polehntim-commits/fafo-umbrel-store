# Patent Pending — Provisional patent filed April 14, 2026. All rights reserved.
import io
import json
import os
import random
import shutil
import tempfile
import zipfile
from flask import Blueprint, render_template, request, send_file, flash, redirect, url_for, current_app
from app.models import Project, Image, Annotation

export_bp = Blueprint('export', __name__)


def _split_images(images, train_ratio, val_ratio, seed=42):
    """Return (train, val, test) lists from a shuffled copy."""
    imgs = list(images)
    random.Random(seed).shuffle(imgs)
    n = len(imgs)
    train_end = int(n * train_ratio)
    val_end = train_end + int(n * val_ratio)
    return imgs[:train_end], imgs[train_end:val_end], imgs[val_end:]


@export_bp.route('/projects/<int:project_id>/export')
def export_page(project_id):
    project = Project.query.get_or_404(project_id)
    annotated = [img for img in project.images if img.is_annotated]
    return render_template('projects/export.html', project=project, annotated_count=len(annotated))


@export_bp.route('/projects/<int:project_id>/export/yolo-bbox', methods=['POST'])
def export_yolo_bbox(project_id):
    project = Project.query.get_or_404(project_id)
    train_r, val_r, test_r, seed = _parse_split_params(request)
    annotated = [img for img in project.images if img.is_annotated]
    train, val, test = _split_images(annotated, train_r, val_r, seed)

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        upload_folder = current_app.config['UPLOAD_FOLDER']
        class_list = project.class_list

        for split_name, split_imgs in [('train', train), ('val', val), ('test', test)]:
            for img in split_imgs:
                _add_image_to_zip(zf, img, upload_folder, split_name)
                label_lines = []
                for ann in img.annotations:
                    if ann.annotation_type != 'bbox':
                        continue
                    cx = ann.bbox_x + ann.bbox_w / 2
                    cy = ann.bbox_y + ann.bbox_h / 2
                    label_lines.append(f'{ann.class_id} {cx:.6f} {cy:.6f} {ann.bbox_w:.6f} {ann.bbox_h:.6f}')
                label_text = '\n'.join(label_lines)
                stem = os.path.splitext(img.filename)[0]
                zf.writestr(f'{split_name}/labels/{stem}.txt', label_text)

        # classes.txt
        zf.writestr('classes.txt', '\n'.join(class_list))

        # data.yaml
        yaml = _make_data_yaml(class_list, has_test=bool(test))
        zf.writestr('data.yaml', yaml)

    buf.seek(0)
    return send_file(buf, mimetype='application/zip', as_attachment=True,
                     download_name=f'{_safe(project.name)}_yolo_bbox.zip')


@export_bp.route('/projects/<int:project_id>/export/yolo-seg', methods=['POST'])
def export_yolo_seg(project_id):
    project = Project.query.get_or_404(project_id)
    train_r, val_r, test_r, seed = _parse_split_params(request)
    annotated = [img for img in project.images if img.is_annotated]
    train, val, test = _split_images(annotated, train_r, val_r, seed)

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        upload_folder = current_app.config['UPLOAD_FOLDER']
        class_list = project.class_list

        for split_name, split_imgs in [('train', train), ('val', val), ('test', test)]:
            for img in split_imgs:
                _add_image_to_zip(zf, img, upload_folder, split_name)
                label_lines = []
                for ann in img.annotations:
                    if ann.annotation_type != 'polygon':
                        continue
                    pts = ann.polygon_list
                    if len(pts) < 3:
                        continue
                    coords = ' '.join(f'{p["x"]:.6f} {p["y"]:.6f}' for p in pts)
                    label_lines.append(f'{ann.class_id} {coords}')
                label_text = '\n'.join(label_lines)
                stem = os.path.splitext(img.filename)[0]
                zf.writestr(f'{split_name}/labels/{stem}.txt', label_text)

        zf.writestr('classes.txt', '\n'.join(class_list))
        yaml = _make_data_yaml(class_list, has_test=bool(test))
        zf.writestr('data.yaml', yaml)

    buf.seek(0)
    return send_file(buf, mimetype='application/zip', as_attachment=True,
                     download_name=f'{_safe(project.name)}_yolo_seg.zip')


@export_bp.route('/projects/<int:project_id>/export/createml', methods=['POST'])
def export_createml(project_id):
    project = Project.query.get_or_404(project_id)
    train_r, val_r, test_r, seed = _parse_split_params(request)
    annotated = [img for img in project.images if img.is_annotated]
    train, val, test = _split_images(annotated, train_r, val_r, seed)

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, 'w', zipfile.ZIP_DEFLATED) as zf:
        upload_folder = current_app.config['UPLOAD_FOLDER']

        for split_name, split_imgs in [('train', train), ('val', val), ('test', test)]:
            entries = []
            for img in split_imgs:
                _add_image_to_zip(zf, img, upload_folder, split_name)
                ann_list = []
                for ann in img.annotations:
                    if ann.annotation_type == 'bbox' and img.width and img.height:
                        # Create ML uses pixel coordinates, center x/y, w/h
                        px_x = (ann.bbox_x + ann.bbox_w / 2) * img.width
                        px_y = (ann.bbox_y + ann.bbox_h / 2) * img.height
                        px_w = ann.bbox_w * img.width
                        px_h = ann.bbox_h * img.height
                        ann_list.append({
                            'label': ann.class_label,
                            'type': 'rectangle',
                            'coordinates': {
                                'x': round(px_x, 2),
                                'y': round(px_y, 2),
                                'width': round(px_w, 2),
                                'height': round(px_h, 2),
                            }
                        })
                    elif ann.annotation_type == 'polygon' and img.width and img.height:
                        pts = ann.polygon_list
                        pixel_pts = [{'x': round(p['x'] * img.width, 2), 'y': round(p['y'] * img.height, 2)} for p in pts]
                        ann_list.append({
                            'label': ann.class_label,
                            'type': 'polygon',
                            'points': pixel_pts,
                        })
                entries.append({'image': img.filename, 'annotations': ann_list})
            zf.writestr(f'{split_name}/annotations.json', json.dumps(entries, indent=2))

    buf.seek(0)
    return send_file(buf, mimetype='application/zip', as_attachment=True,
                     download_name=f'{_safe(project.name)}_createml.zip')


@export_bp.route('/projects/<int:project_id>/export/json', methods=['POST'])
def export_json(project_id):
    project = Project.query.get_or_404(project_id)
    annotated = [img for img in project.images if img.is_annotated]

    manifest = {
        'project': project.name,
        'description': project.description,
        'classes': project.class_list,
        'images': []
    }
    for img in annotated:
        manifest['images'].append({
            'filename': img.filename,
            'original_name': img.original_name,
            'width': img.width,
            'height': img.height,
            'annotations': [a.to_dict() for a in img.annotations],
        })

    buf = io.BytesIO(json.dumps(manifest, indent=2).encode('utf-8'))
    buf.seek(0)
    return send_file(buf, mimetype='application/json', as_attachment=True,
                     download_name=f'{_safe(project.name)}_manifest.json')


# ── helpers ──────────────────────────────────────────────────────────────────

def _parse_split_params(req):
    from flask import current_app
    train_r = float(req.form.get('train', current_app.config['SPLIT_TRAIN']))
    val_r = float(req.form.get('val', current_app.config['SPLIT_VAL']))
    test_r = float(req.form.get('test', current_app.config['SPLIT_TEST']))
    seed = int(req.form.get('seed', 42))
    # Normalize so they sum to 1
    total = train_r + val_r + test_r
    if total > 0:
        train_r, val_r, test_r = train_r / total, val_r / total, test_r / total
    return train_r, val_r, test_r, seed


def _add_image_to_zip(zf, img, upload_folder, split_name):
    src = os.path.join(upload_folder, img.filename)
    if os.path.exists(src):
        zf.write(src, f'{split_name}/images/{img.filename}')


def _make_data_yaml(class_list, has_test=False):
    nc = len(class_list)
    names = ', '.join(f"'{c}'" for c in class_list)
    lines = [
        'path: .',
        'train: train/images',
        'val: val/images',
    ]
    if has_test:
        lines.append('test: test/images')
    lines += [f'nc: {nc}', f'names: [{names}]']
    return '\n'.join(lines) + '\n'


def _safe(name):
    return ''.join(c if c.isalnum() or c in '-_' else '_' for c in name)
