import os

BASE_DIR = os.path.abspath(os.path.dirname(__file__))
DATA_DIR = os.path.abspath(os.environ.get('DATA_DIR', os.path.join(BASE_DIR, 'data')))


class Config:
    SECRET_KEY = os.environ.get('SECRET_KEY', 'dev-secret-change-in-production')
    SQLALCHEMY_DATABASE_URI = 'sqlite:///' + os.path.join(DATA_DIR, 'volume_vision.db')
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    UPLOAD_FOLDER = os.path.join(DATA_DIR, 'uploads')
    MAX_CONTENT_LENGTH = 100 * 1024 * 1024  # 100 MB per request
    APP_PASSWORD = os.environ.get('APP_PASSWORD', 'changeme')
    # Export train/val/test split defaults
    SPLIT_TRAIN = float(os.environ.get('SPLIT_TRAIN', '0.70'))
    SPLIT_VAL = float(os.environ.get('SPLIT_VAL', '0.20'))
    SPLIT_TEST = float(os.environ.get('SPLIT_TEST', '0.10'))
