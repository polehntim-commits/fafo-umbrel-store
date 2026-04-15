# Patent Pending — Provisional patent filed April 14, 2026. All rights reserved.
import os
from flask import Flask, session, redirect, url_for, request, render_template_string
from flask_sqlalchemy import SQLAlchemy
from config import Config

db = SQLAlchemy()


def create_app():
    app = Flask(__name__)
    app.config.from_object(Config)

    # Ensure data dir and uploads dir exist before SQLite tries to open the DB
    data_dir = os.environ.get('DATA_DIR', os.path.join(os.path.abspath(os.path.dirname(os.path.dirname(__file__))), 'data'))
    os.makedirs(data_dir, exist_ok=True)
    os.makedirs(app.config['UPLOAD_FOLDER'], exist_ok=True)

    db.init_app(app)

    # Auth middleware
    @app.before_request
    def require_auth():
        public = {'auth.login', 'auth.logout', 'static'}
        if request.endpoint and request.endpoint.split('.')[0] not in ('auth',) and request.endpoint != 'static':
            if not session.get('authenticated'):
                return redirect(url_for('auth.login', next=request.url))

    # Simple auth blueprint (inline, no separate file needed)
    from flask import Blueprint, flash
    auth_bp = Blueprint('auth', __name__)

    LOGIN_TMPL = """
<!doctype html>
<html>
<head><title>Volume Vision — Login</title>
<style>
  body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0;
         display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
  .card { background: #1e293b; padding: 2rem; border-radius: 12px; width: 320px; }
  h1 { margin: 0 0 1.5rem; font-size: 1.4rem; color: #38bdf8; }
  input { width: 100%; padding: .6rem .8rem; border: 1px solid #334155;
          border-radius: 6px; background: #0f172a; color: #e2e8f0;
          font-size: 1rem; box-sizing: border-box; margin-bottom: 1rem; }
  button { width: 100%; padding: .7rem; background: #0ea5e9; color: #fff;
           border: none; border-radius: 6px; font-size: 1rem; cursor: pointer; }
  button:hover { background: #38bdf8; }
  .err { color: #f87171; margin-bottom: 1rem; font-size: .9rem; }
</style></head>
<body>
<div class="card">
  <h1>Volume Vision</h1>
  {% if error %}<p class="err">{{ error }}</p>{% endif %}
  <form method="post">
    <input type="password" name="password" placeholder="Password" autofocus>
    <button type="submit">Enter</button>
  </form>
</div>
</body></html>
"""

    @auth_bp.route('/login', methods=['GET', 'POST'])
    def login():
        error = None
        if request.method == 'POST':
            if request.form.get('password') == app.config['APP_PASSWORD']:
                session['authenticated'] = True
                return redirect(request.args.get('next') or url_for('projects.list_projects'))
            error = 'Incorrect password.'
        return render_template_string(LOGIN_TMPL, error=error)

    @auth_bp.route('/logout')
    def logout():
        session.clear()
        return redirect(url_for('auth.login'))

    app.register_blueprint(auth_bp)

    from app.routes.projects import projects_bp
    from app.routes.annotate import annotate_bp
    from app.routes.export import export_bp

    app.register_blueprint(projects_bp)
    app.register_blueprint(annotate_bp)
    app.register_blueprint(export_bp)

    with app.app_context():
        db.create_all()

    return app
