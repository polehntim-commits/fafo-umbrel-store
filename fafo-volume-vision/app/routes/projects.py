# Patent Pending — Provisional patent filed April 14, 2026. All rights reserved.
import os
import uuid
import json
from flask import Blueprint, render_template, request, redirect, url_for, flash, current_app, send_from_directory
from PIL import Image as PILImage
from app import db
from app.models import Project, Image

projects_bp = Blueprint('projects', __name__)


@projects_bp.route('/')
def list_projects():
    projects = Project.query.order_by(Project.updated_at.desc()).all()
    return render_template('projects/list.html', projects=projects)


@projects_bp.route('/projects/new', methods=['GET', 'POST'])
def new_project():
    if request.method == 'POST':
        name = request.form.get('name', '').strip()
        if not name:
            flash('Project name is required.', 'error')
            return render_template('projects/form.html', project=None)
        description = request.form.get('description', '').strip()
        classes_raw = request.form.get('classes', '').strip()
        class_list = [c.strip() for c in classes_raw.splitlines() if c.strip()]
        project = Project(
            name=name,
            description=description,
            classes=json.dumps(class_list),
        )
        db.session.add(project)
        db.session.commit()
        flash(f'Project "{name}" created.', 'success')
        return redirect(url_for('projects.view_project', project_id=project.id))
    return render_template('projects/form.html', project=None)


@projects_bp.route('/projects/<int:project_id>')
def view_project(project_id):
    project = Project.query.get_or_404(project_id)
    return render_template('projects/view.html', project=project)


@projects_bp.route('/projects/<int:project_id>/edit', methods=['GET', 'POST'])
def edit_project(project_id):
    project = Project.query.get_or_404(project_id)
    if request.method == 'POST':
        name = request.form.get('name', '').strip()
        if not name:
            flash('Project name is required.', 'error')
            return render_template('projects/form.html', project=project)
        project.name = name
        project.description = request.form.get('description', '').strip()
        classes_raw = request.form.get('classes', '').strip()
        class_list = [c.strip() for c in classes_raw.splitlines() if c.strip()]
        project.classes = json.dumps(class_list)
        db.session.commit()
        flash('Project updated.', 'success')
        return redirect(url_for('projects.view_project', project_id=project.id))
    return render_template('projects/form.html', project=project)


@projects_bp.route('/projects/<int:project_id>/delete', methods=['POST'])
def delete_project(project_id):
    project = Project.query.get_or_404(project_id)
    # Remove image files from disk
    upload_folder = current_app.config['UPLOAD_FOLDER']
    for img in project.images:
        filepath = os.path.join(upload_folder, img.filename)
        if os.path.exists(filepath):
            os.remove(filepath)
    db.session.delete(project)
    db.session.commit()
    flash(f'Project "{project.name}" deleted.', 'success')
    return redirect(url_for('projects.list_projects'))


@projects_bp.route('/projects/<int:project_id>/upload', methods=['POST'])
def upload_images(project_id):
    project = Project.query.get_or_404(project_id)
    files = request.files.getlist('images')
    upload_folder = current_app.config['UPLOAD_FOLDER']
    allowed = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif'}
    added = 0
    errors = []

    for f in files:
        if not f or not f.filename:
            continue
        ext = os.path.splitext(f.filename)[1].lower()
        if ext not in allowed:
            errors.append(f'{f.filename}: unsupported type')
            continue
        stored_name = f'{uuid.uuid4().hex}{ext}'
        dest = os.path.join(upload_folder, stored_name)
        f.save(dest)
        try:
            with PILImage.open(dest) as pil_img:
                width, height = pil_img.size
        except Exception:
            width, height = None, None
        img = Image(
            filename=stored_name,
            original_name=f.filename,
            width=width,
            height=height,
            project_id=project.id,
        )
        db.session.add(img)
        added += 1

    db.session.commit()
    if added:
        flash(f'{added} image(s) uploaded.', 'success')
    for e in errors:
        flash(e, 'error')
    return redirect(url_for('projects.view_project', project_id=project.id))


@projects_bp.route('/uploads/<filename>')
def uploaded_file(filename):
    return send_from_directory(current_app.config['UPLOAD_FOLDER'], filename)
