#!/usr/bin/env python3
"""Generate benchmark comparison graphs from committed result JSON files."""

from __future__ import annotations

import json
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "bench" / "results"
OUT = ROOT / "bench" / "graphs"
OUT.mkdir(parents=True, exist_ok=True)

LANGS = ["Ruby", "Elixir", "Go", "Rust"]
COLORS = {
    "Ruby": "#CC342D",
    "Elixir": "#7e57c2",
    "Go": "#00ADD8",
    "Rust": "#ce422b",
}
BASELINE_LABEL = {
    "Ruby": "baseline",
    "Elixir": "elixir120rc5-otp29-jason",
    "Go": "baseline",
    "Rust": "baseline",
}
OPT_LABEL = {
    "Ruby": "oj-yjit",
    "Elixir": "elixir120rc5-otp29-json",
    "Go": "goccy-gogc200",
    "Rust": "simd-json",
}
OPT_NAME = {
    "Ruby": "oj + YJIT",
    "Elixir": "OTP29 :json",
    "Go": "goccy + GOGC=200",
    "Rust": "simd-json",
}

# Apple M4 Pro values from RESULTS.md. The JSON corpus on this branch contains
# the x86_64 reruns, so keep the published M4 comparison values here explicitly.
M4_BASELINE_RPS = {
    1: {"Ruby": 7807, "Elixir": 7078, "Go": 7710, "Rust": 20293},
    4: {"Ruby": 25136, "Elixir": 27918, "Go": 23733, "Rust": 63159},
}
M4_OPT_RPS = {
    1: {"Ruby": 9490, "Elixir": 7792, "Go": 12364, "Rust": 21393},
    4: {"Ruby": 30261, "Elixir": 30014, "Go": 37007, "Rust": 67574},
}


def load(lang: str, cores: int, label: str) -> dict:
    path = RESULTS / f"{lang.lower()}-{cores}c-{label}.json"
    with path.open() as f:
        return json.load(f)


def x86_dataset(labels: dict[str, str]) -> dict[int, dict[str, dict]]:
    return {cores: {lang: load(lang, cores, labels[lang]) for lang in LANGS} for cores in (1, 4)}


def annotate_bars(ax, bars, fmt="{:.0f}"):
    for bar in bars:
        h = bar.get_height()
        ax.annotate(fmt.format(h), xy=(bar.get_x() + bar.get_width() / 2, h),
                    xytext=(0, 3), textcoords="offset points", ha="center", va="bottom", fontsize=8)


def style(ax, title: str, ylabel: str):
    ax.set_title(title, loc="left", fontweight="bold")
    ax.set_ylabel(ylabel)
    ax.grid(axis="y", alpha=0.25)
    ax.spines[["top", "right"]].set_visible(False)


def save(fig, name: str):
    fig.tight_layout()
    fig.savefig(OUT / f"{name}.png", dpi=180, bbox_inches="tight")
    fig.savefig(OUT / f"{name}.svg", bbox_inches="tight")
    plt.close(fig)


def graph_x86_rps():
    data = x86_dataset(OPT_LABEL)
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), sharey=True)
    ymax = max(data[c][l]["rps"] for c in (1, 4) for l in LANGS) * 1.18
    for ax, cores in zip(axes, (1, 4)):
        vals = [data[cores][l]["rps"] for l in LANGS]
        bars = ax.bar(LANGS, vals, color=[COLORS[l] for l in LANGS])
        annotate_bars(ax, bars, "{:.0f}")
        ax.set_ylim(0, ymax)
        style(ax, f"x86_64 optimized throughput — {cores} core{'s' if cores > 1 else ''}", "requests/sec")
        ax.tick_params(axis="x", rotation=20)
    save(fig, "x86_optimized_rps_by_language")


def graph_core_scaling():
    data = x86_dataset(OPT_LABEL)
    vals = [data[4][l]["rps"] / data[1][l]["rps"] for l in LANGS]
    fig, ax = plt.subplots(figsize=(8, 5))
    bars = ax.bar(LANGS, vals, color=[COLORS[l] for l in LANGS])
    ax.axhline(4, color="#333", linestyle="--", linewidth=1, label="ideal 4×")
    annotate_bars(ax, bars, "{:.2f}×")
    style(ax, "4-core scaling from optimized 1-core run", "4c rps / 1c rps")
    ax.legend(frameon=False)
    save(fig, "x86_optimized_core_scaling")


def graph_arch_comparison():
    x86 = x86_dataset(OPT_LABEL)
    x = np.arange(len(LANGS))
    width = 0.36
    fig, axes = plt.subplots(1, 2, figsize=(13, 5), sharey=True)
    for ax, cores in zip(axes, (1, 4)):
        m4_vals = [M4_OPT_RPS[cores][l] for l in LANGS]
        x86_vals = [x86[cores][l]["rps"] for l in LANGS]
        ax.bar(x - width / 2, m4_vals, width, label="Apple M4 Pro", color="#94a3b8")
        ax.bar(x + width / 2, x86_vals, width, label="x86_64 EPYC", color="#f97316")
        ax.set_xticks(x, LANGS, rotation=20)
        style(ax, f"Optimized throughput by architecture — {cores}c", "requests/sec")
        for i, (m4, amd) in enumerate(zip(m4_vals, x86_vals)):
            delta = (amd / m4 - 1) * 100
            ax.annotate(f"{delta:+.0f}%", xy=(i + width / 2, amd), xytext=(0, 3),
                        textcoords="offset points", ha="center", va="bottom", fontsize=8)
    axes[0].legend(frameon=False)
    save(fig, "optimized_arch_comparison_m4_vs_x86")


def graph_memory():
    data = x86_dataset(OPT_LABEL)
    fig, axes = plt.subplots(1, 2, figsize=(12, 4.8), sharey=True)
    ymax = max(data[c][l]["server_memory_rss_max_mb"] for c in (1, 4) for l in LANGS) * 1.18
    for ax, cores in zip(axes, (1, 4)):
        vals = [data[cores][l]["server_memory_rss_max_mb"] for l in LANGS]
        bars = ax.bar(LANGS, vals, color=[COLORS[l] for l in LANGS])
        annotate_bars(ax, bars, "{:.0f} MB")
        ax.set_ylim(0, ymax)
        style(ax, f"x86_64 optimized peak process-tree RSS — {cores}c", "max RSS (MiB)")
        ax.tick_params(axis="x", rotation=20)
    save(fig, "x86_optimized_memory_rss")


def graph_latency_throughput():
    data = x86_dataset(OPT_LABEL)
    fig, ax = plt.subplots(figsize=(8, 5.6))
    for lang in LANGS:
        for cores, marker in [(1, "o"), (4, "s")]:
            d = data[cores][lang]
            ax.scatter(d["p99_us"] / 1000, d["rps"], s=120 if cores == 4 else 80,
                       marker=marker, color=COLORS[lang], edgecolor="white", linewidth=0.7)
            ax.annotate(f"{lang} {cores}c", (d["p99_us"] / 1000, d["rps"]),
                        xytext=(5, 4), textcoords="offset points", fontsize=8)
    style(ax, "Throughput vs p99 latency — x86_64 optimized", "requests/sec")
    ax.set_xlabel("p99 latency (ms, lower is better)")
    save(fig, "x86_optimized_latency_vs_throughput")


def main() -> None:
    plt.rcParams.update({
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "font.size": 10,
        "axes.titlesize": 12,
    })
    graph_x86_rps()
    graph_core_scaling()
    graph_arch_comparison()
    graph_memory()
    graph_latency_throughput()
    print(f"wrote graphs to {OUT}")


if __name__ == "__main__":
    main()
