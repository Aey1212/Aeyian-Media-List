"""Turning stored values into display text."""

from __future__ import annotations

from decimal import Decimal
from typing import Any


def pick_label(labels: dict[str, Any] | None, lang: str) -> str | None:
    """Text from a core.labels value: the wanted language, else the native one, else the first."""
    if not labels:
        return None
    if lang in labels:
        return labels[lang]["text"]
    for entry in labels.values():
        if entry.get("native"):
            return entry["text"]
    return next(iter(labels.values()))["text"]


def format_partial_date(value: str | None) -> str | None:
    """'2024-02-02' -> '2024/02/02'; '2024-02' -> '2024/02'; '2024' -> '2024'."""
    return value.replace("-", "/") if value else None


def format_number(value: Decimal | int | None) -> str | None:
    """88.000 -> '88', 8.450 -> '8.45', 0.5 -> '0.5'."""
    if value is None:
        return None
    text = f"{Decimal(value).normalize():f}"
    return "0" if text in ("-0", "0") else text


def format_signed(value: Decimal | int | float) -> str:
    """A shown score with its sign: '+6.4', '−3.0' (true minus sign), '0.0'."""
    number = Decimal(str(value))
    if number > 0:
        return f"+{number:.1f}"
    if number < 0:
        return f"−{-number:.1f}"
    return "0.0"
