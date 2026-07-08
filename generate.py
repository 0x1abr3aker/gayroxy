#!/usr/bin/env python3
"""Render Jinja2 templates for proxy.sh

Reads a JSON config from stdin and renders templates to output files.
Usage: cat config.json | ./generate.py [--outdir DIR]
"""

import json
import os
import sys
from pathlib import Path


SITE_PACKAGES = ""

def _ensure_jinja2():
    global SITE_PACKAGES
    """Try to import jinja2, install if missing."""
    try:
        import jinja2
        return jinja2
    except ImportError:
        import subprocess
        import site
        subprocess.check_call([sys.executable, "-m", "pip", "install", "-q", "jinja2"])
        import jinja2
        return jinja2


def render_template(jinja2, template_path: str, context: dict) -> str:
    env = jinja2.Environment(
        loader=jinja2.FileSystemLoader(os.path.dirname(template_path) or "."),
        autoescape=False,
    )
    template = env.get_template(os.path.basename(template_path))
    return template.render(**context)


def main():
    outdir = Path.cwd()
    if "--outdir" in sys.argv:
        idx = sys.argv.index("--outdir")
        outdir = Path(sys.argv[idx + 1])
        outdir.mkdir(parents=True, exist_ok=True)

    config = json.load(sys.stdin)
    jinja2 = _ensure_jinja2()

    templates_dir = Path(__file__).parent / "templates"
    if not templates_dir.exists():
        templates_dir = Path("templates")

    # Render each .j2 file
    outputs = {
        "config.json": "xray.json.j2",
        "nginx.conf": "nginx.conf.j2",
        "panel.html": "panel.html.j2",
    }

    for outfile, template_name in outputs.items():
        template_path = templates_dir / template_name
        if not template_path.exists():
            print(f"Warning: template {template_path} not found, skipping", file=sys.stderr)
            continue
        output = render_template(jinja2, str(template_path), config)
        target = outdir / outfile
        target.write_text(output)
        print(f"Rendered {target}")

    # Subscription base64 file
    sub_file = outdir / "sub" / "subscription.b64"
    sub_file.parent.mkdir(parents=True, exist_ok=True)
    if "sub_content" in config:
        import base64
        sub_file.write_text(base64.b64encode(config["sub_content"].encode()).decode())
        print(f"Rendered {sub_file}")


if __name__ == "__main__":
    main()
