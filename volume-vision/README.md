# Volume Vision

A focused ML annotation tool for training data management. Upload images, draw bounding boxes and polygon masks, export to YOLO or Create ML format.

## Quick start

```bash
pip install -r requirements.txt
DATA_DIR=./data APP_PASSWORD=yourpassword python run.py
```

Open `http://localhost:5100`

## Docker

```bash
APP_PASSWORD=yourpassword docker-compose up -d
```

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `APP_PASSWORD` | `changeme` | Login password |
| `SECRET_KEY` | dev key | Flask session secret |
| `DATA_DIR` | `./data` | Path for SQLite DB + uploaded images |
| `PORT` | `5100` | Server port |
| `SPLIT_TRAIN` | `0.70` | Default train split ratio |
| `SPLIT_VAL` | `0.20` | Default val split ratio |
| `SPLIT_TEST` | `0.10` | Default test split ratio |

## Export formats

- **YOLO bbox** — `class cx cy w h` normalized, train/val/test split
- **YOLO segmentation** — `class x1 y1 x2 y2 …` polygon points
- **Create ML** — JSON with pixel-coordinate bbox and polygon annotations
- **JSON manifest** — raw normalized annotations for custom pipelines

## Keyboard shortcuts (annotation screen)

| Key | Action |
|---|---|
| `B` | Bounding box tool |
| `P` | Polygon tool |
| `S` | Save annotations |
| `Delete` | Delete selected annotation |
| `Esc` | Cancel in-progress polygon |
