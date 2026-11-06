#!/usr/bin/env python3
"""Regenerate benchmark SVGs from docs/benchmarks/data.json (stdlib only)."""

import json
from pathlib import Path
from xml.etree import ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif'
PALETTES = {
    "light": ("#1865EE", "#1f2328", "#59636e"),
    "dark": ("#4C8DFF", "#e6edf3", "#9198a1"),
}


def text(svg, x, y, value, color, bold=False, anchor="start"):
    node = ET.SubElement(svg, "text", {
        "x": str(x), "y": str(y), "fill": color,
        "text-anchor": anchor, "font-weight": "700" if bold else "400",
    })
    node.text = value


def chart(height):
    return ET.Element("svg", {
        "xmlns": "http://www.w3.org/2000/svg", "width": "720",
        "height": str(height), "viewBox": f"0 0 720 {height}",
        "font-family": FONT, "font-size": "13",
    })


def bars(rows, key, unit, blue, foreground, muted):
    svg = chart(30 * len(rows) + 16)
    maximum = max(row[key] for row in rows)
    for i, row in enumerate(sorted(rows, key=lambda row: row[key])):
        y = 20 + 30 * i
        nib = row["name"] == "nib"
        color = blue if nib else muted
        width = row[key] / maximum * 400
        text(svg, 185, y + 5, row["name"], color, nib, "end")
        ET.SubElement(svg, "rect", {
            "x": "200", "y": str(y - 8), "width": str(width),
            "height": "16", "rx": "4", "fill": blue if nib else "#6E7781",
            "opacity": "1" if nib else "0.5",
        })
        text(svg, 208 + width, y + 5, f'{row[key]:,} {unit}', color, nib)
    return svg


def costs(rows, blue, foreground, muted):
    svg = chart(30 * len(rows) + 52)
    maximum = max(row["codex"] for row in rows)
    for i, row in enumerate(sorted(rows, key=lambda row: row["nib"])):
        y = 20 + 30 * i
        left = 240 + row["nib"] / maximum * 350
        right = 240 + row["codex"] / maximum * 350
        text(svg, 185, y + 5, row["task"], muted, anchor="end")
        ET.SubElement(svg, "line", {
            "x1": str(left), "x2": str(right), "y1": str(y), "y2": str(y),
            "stroke": "#6E7781", "stroke-opacity": "0.5", "stroke-width": "1",
        })
        for x, color in [(left, blue), (right, "#6E7781")]:
            ET.SubElement(svg, "circle", {"cx": str(x), "cy": str(y), "r": "4", "fill": color})
        text(svg, left - 12, y + 5, f'${row["nib"]:.3f}', blue, True, "end")
        text(svg, right + 12, y + 5, f'${row["codex"]:.3f}', muted)
    y = 30 * len(rows) + 25
    for x, label, color in [(245, "nib", blue), (320, "Codex CLI", muted)]:
        ET.SubElement(svg, "circle", {"cx": str(x), "cy": str(y - 4), "r": "4", "fill": blue if label == "nib" else "#6E7781"})
        text(svg, x + 12, y, label, color, label == "nib")
    return svg


def main():
    data = json.loads((ROOT / "docs/benchmarks/data.json").read_text())
    output = ROOT / "docs/assets"
    output.mkdir(parents=True, exist_ok=True)
    for theme, palette in PALETTES.items():
        charts = {
            "memory": bars(data["footprint"], "ten_rss_mb", "MB", *palette),
            "prompt": bars(data["footprint"], "prompt_tokens", "tokens", *palette),
            "cost": costs(data["comparison"]["task_cost_usd"], *palette),
        }
        for name, svg in charts.items():
            width, height = map(float, svg.attrib["viewBox"].split()[2:])
            for node in svg:
                if node.tag == "text":
                    assert 0 < float(node.attrib["x"]) < width
                    assert 0 < float(node.attrib["y"]) < height
            ET.indent(svg)
            path = output / f"bench-{name}-{theme}.svg"
            ET.ElementTree(svg).write(path, encoding="utf-8", xml_declaration=True)
            ET.parse(path)


if __name__ == "__main__":
    main()
