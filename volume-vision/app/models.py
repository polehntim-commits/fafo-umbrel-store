# Patent Pending — Provisional patent filed April 14, 2026. All rights reserved.
import json
from datetime import datetime
from app import db


class Project(db.Model):
    __tablename__ = 'project'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(200), nullable=False)
    description = db.Column(db.Text)
    classes = db.Column(db.Text, default='[]')  # JSON list of class name strings
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

    images = db.relationship('Image', backref='project', lazy=True, cascade='all, delete-orphan')

    @property
    def class_list(self):
        try:
            return json.loads(self.classes or '[]')
        except (json.JSONDecodeError, TypeError):
            return []

    @class_list.setter
    def class_list(self, value):
        self.classes = json.dumps(value)

    @property
    def annotated_count(self):
        return sum(1 for img in self.images if img.is_annotated)

    @property
    def total_count(self):
        return len(self.images)

    def __repr__(self):
        return f'<Project {self.name}>'


class Image(db.Model):
    __tablename__ = 'image'

    id = db.Column(db.Integer, primary_key=True)
    filename = db.Column(db.String(500), nullable=False)      # stored filename (UUID-based)
    original_name = db.Column(db.String(500))                  # original upload name
    width = db.Column(db.Integer)
    height = db.Column(db.Integer)
    project_id = db.Column(db.Integer, db.ForeignKey('project.id'), nullable=False)
    uploaded_at = db.Column(db.DateTime, default=datetime.utcnow)
    is_annotated = db.Column(db.Boolean, default=False)

    annotations = db.relationship('Annotation', backref='image', lazy=True, cascade='all, delete-orphan')

    def __repr__(self):
        return f'<Image {self.filename}>'


class Annotation(db.Model):
    __tablename__ = 'annotation'

    id = db.Column(db.Integer, primary_key=True)
    image_id = db.Column(db.Integer, db.ForeignKey('image.id'), nullable=False)
    annotation_type = db.Column(db.String(20), nullable=False)  # "bbox" or "polygon"
    class_label = db.Column(db.String(200), nullable=False)
    class_id = db.Column(db.Integer, nullable=False)

    # Bounding box — normalized (0..1), top-left origin, width/height
    bbox_x = db.Column(db.Float)
    bbox_y = db.Column(db.Float)
    bbox_w = db.Column(db.Float)
    bbox_h = db.Column(db.Float)

    # Polygon — JSON array of {"x": float, "y": float} normalized points
    polygon_points = db.Column(db.Text)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    @property
    def polygon_list(self):
        try:
            return json.loads(self.polygon_points or '[]')
        except (json.JSONDecodeError, TypeError):
            return []

    def to_dict(self):
        d = {
            'id': self.id,
            'type': self.annotation_type,
            'class_label': self.class_label,
            'class_id': self.class_id,
        }
        if self.annotation_type == 'bbox':
            d['bbox'] = {'x': self.bbox_x, 'y': self.bbox_y, 'w': self.bbox_w, 'h': self.bbox_h}
        else:
            d['polygon'] = self.polygon_list
        return d

    def __repr__(self):
        return f'<Annotation {self.annotation_type} class={self.class_label}>'
