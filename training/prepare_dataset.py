#!/usr/bin/env python3
"""Turns the app's dataset ZIP into the COCO layout RF-DETR trains on.

Input: the ZIP from the app's "Ekspor dataset" button (images/, labels/,
data.yaml, annotations_coco.json). Output:

    OUTPUT/train/_annotations.coco.json + images
    OUTPUT/valid/_annotations.coco.json + images
    OUTPUT/test/_annotations.coco.json  + images

Usage: python prepare_dataset.py dataset_123.zip rfdetr_dataset [--valid 0.15] [--test 0.1]
"""
import argparse
import json
import random
import shutil
import sys
import zipfile
from pathlib import Path, PurePosixPath


def split_counts(total: int, valid: float, test: float) -> tuple[int, int, int]:
    if total < 3:
        raise ValueError("Butuh minimal 3 foto beranotasi (1 train, 1 valid, 1 test).")
    n_valid = max(1, round(total * valid))
    n_test = max(1, round(total * test))
    n_train = total - n_valid - n_test
    if n_train < 1:
        raise ValueError("Porsi valid/test terlalu besar untuk jumlah foto ini.")
    return n_train, n_valid, n_test


def prepare(zip_path: Path, output: Path, valid: float, test: float, seed: int) -> dict[str, int]:
    with zipfile.ZipFile(zip_path) as archive:
        coco = json.loads(archive.read("annotations_coco.json"))
        images = sorted(coco["images"], key=lambda image: image["file_name"])
        random.Random(seed).shuffle(images)
        n_train, n_valid, _ = split_counts(len(images), valid, test)
        splits = {
            "train": images[:n_train],
            "valid": images[n_train:n_train + n_valid],
            "test": images[n_train + n_valid:],
        }
        if output.exists():
            shutil.rmtree(output)
        counts = {}
        for split, members in splits.items():
            directory = output / split
            directory.mkdir(parents=True)
            ids = {image["id"] for image in members}
            for image in members:
                name = PurePosixPath(image["file_name"]).name
                if name != image["file_name"] or name.startswith("."):
                    raise ValueError(f"Nama file tidak aman: {image['file_name']!r}")
                (directory / name).write_bytes(archive.read(f"images/{name}"))
            annotations = [a for a in coco["annotations"] if a["image_id"] in ids]
            (directory / "_annotations.coco.json").write_text(json.dumps({
                "images": members,
                "annotations": annotations,
                "categories": coco["categories"],
            }))
            counts[split] = len(members)
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("zip", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--valid", type=float, default=0.15)
    parser.add_argument("--test", type=float, default=0.10)
    parser.add_argument("--seed", type=int, default=0)
    args = parser.parse_args()
    try:
        counts = prepare(args.zip, args.output, args.valid, args.test, args.seed)
    except (ValueError, KeyError) as error:
        print(f"Gagal: {error}", file=sys.stderr)
        return 1
    print(", ".join(f"{split}: {count} foto" for split, count in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
