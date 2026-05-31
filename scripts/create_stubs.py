#!/usr/bin/env python3
"""
Create header-only stub data files required for the Flutter build.

Run this once after cloning the repository before the first build.
No internet access is needed.  The stubs contain only the TSV header row so
city_service.dart treats each dataset as empty (unavailable) and the app
starts with just the committed cities.tsv (top-5 000 cities).

Afterwards, run the fetch scripts to download real data:
  python scripts/fetch_cities.py              -- city datasets
  python scripts/fetch_ports.py --wpi-file …  -- port dataset

The stub files are gitignored; they can never be accidentally committed.
"""
from pathlib import Path

ASSETS = Path(__file__).parent.parent / "assets"

STUBS: dict[str, str] = {
    "cities_precise.tsv":  "name\tcountry\tlat\tlon\tpopulation\ttimezone\n",
    "cities_detailed.tsv": "name\tcountry\tlat\tlon\tpopulation\ttimezone\n",
    "ports.tsv": (
        "name\tcountry\tlat\tlon\ttype\tsize\tvhf\tphone\tcall_sign"
        "\twpi_index\tfacilities"
        "\tharbor_type\tharbor_use\tshelter"
        "\ttidal_range_m\tchannel_depth_m\tmax_vessel_length_m"
        "\tchart\tnavarea\tpublication\tpublication_link"
        "\tpilotage\tentry_restrictions\tfirst_port_entry\n"
    ),
}


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    for name, header in STUBS.items():
        path = ASSETS / name
        if path.exists() and path.stat().st_size > len(header) + 10:
            print(f"  Skipped  {name}  ({path.stat().st_size:,} bytes — looks like real data)")
        else:
            path.write_text(header, encoding="utf-8", newline="\n")
            print(f"  Created  {name}  (stub)")


if __name__ == "__main__":
    main()
