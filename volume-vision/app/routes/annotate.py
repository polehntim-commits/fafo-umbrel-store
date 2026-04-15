# Patent Pending — Provisional patent filed April 14, 2026. All rights reserved.
import json
from flask import Blueprint, render_template, request, redirect, url_for, flash, jsonify
from app import db
from app.models import Project, Image, Annotation

annotate_bp = Blueprint('annotate', __name__)


@annotate_bp.route('/projects/<int:project_id>/queue')
def queue(project_id):
    project = Project.query.get_or_404(project_id)
    show = request.args.get('show', 'unannotated')
    if show == 'all':
        images = Image.query.filter_by(project_id=project_id).order_by(Image.uploaded_at).all()
    elif show == 'annotated':
        images = Image.query.filter_by(project_id=project_id, is_annotated=True).order_by(Image.uploaded_at).all()
    else:
        images = Image.query.filter_by(project_id=project_id, is_annotated=False).order_by(Image.uploaded_at).all()
    return render_template('annotate/queue.html', project=project, images=images, show=show)


@annotate_bp.route('/projects/<int:project_id>/annotate/<int:image_id>', methods=['GET'])
def label(project_id, image_id):
    project = Project.query.get_or_404(project_id)
    image = Image.query.filter_by(id=image_id, project_id=project_id).first_or_404()
    # Determine next/prev in queue for navigation
    queue_images = Image.query.filter_by(project_id=project_id).order_by(Image.uploaded_at).all()
    ids = [img.id for img in queue_images]
    idx = ids.index(image_id) if image_id in ids else 0
    prev_id = ids[idx - 1] if idx > 0 else None
    next_id = ids[idx + 1] if idx < len(ids) - 1 else None
    existing = [a.to_dict() for a in image.annotations]
    return render_template(
        'annotate/label.html',
        project=project,
        image=image,
        existing_annotations=json.dumps(existing),
        prev_id=prev_id,
        next_id=next_id,
    )


@annotate_bp.route('/projects/<int:project_id>/annotate/<int:image_id>/save', methods=['POST'])
def save_annotations(project_id, image_id):
    image = Image.query.filter_by(id=image_id, project_id=project_id).first_or_404()
    project = Project.query.get_or_404(project_id)

    data = request.get_json()
    if data is None:
        return jsonify({'error': 'Invalid JSON'}), 400

    annotations = data.get('annotations', [])

    # Delete existing and replace
    Annotation.query.filter_by(image_id=image_id).delete()

    class_list = project.class_list
    class_index = {name: i for i, name in enumerate(class_list)}

    for ann in annotations:
        ann_type = ann.get('type')
        class_label = ann.get('class_label', '')
        class_id = class_index.get(class_label, ann.get('class_id', 0))

        if ann_type == 'bbox':
            bbox = ann.get('bbox', {})
            new_ann = Annotation(
                image_id=image_id,
                annotation_type='bbox',
                class_label=class_label,
                class_id=class_id,
                bbox_x=float(bbox.get('x', 0)),
                bbox_y=float(bbox.get('y', 0)),
                bbox_w=float(bbox.get('w', 0)),
                bbox_h=float(bbox.get('h', 0)),
            )
        elif ann_type == 'polygon':
            points = ann.get('polygon', [])
            new_ann = Annotation(
                image_id=image_id,
                annotation_type='polygon',
                class_label=class_label,
                class_id=class_id,
                polygon_points=json.dumps(points),
            )
        else:
            continue

        db.session.add(new_ann)

    image.is_annotated = len(annotations) > 0
    db.session.commit()
    return jsonify({'status': 'ok', 'count': len(annotations)})


@annotate_bp.route('/projects/<int:project_id>/images/<int:image_id>/delete', methods=['POST'])
def delete_image(project_id, image_id):
    import os
    from flask import current_app
    image = Image.query.filter_by(id=image_id, project_id=project_id).first_or_404()
    filepath = os.path.join(current_app.config['UPLOAD_FOLDER'], image.filename)
    if os.path.exists(filepath):
        os.remove(filepath)
    db.session.delete(image)
    db.session.commit()
    flash('Image deleted.', 'success')
    return redirect(url_for('annotate.queue', project_id=project_id))
