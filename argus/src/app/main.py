import argparse
import logging
import sys

from app.config import Settings
from app.pipeline import run


def main() -> None:
    parser = argparse.ArgumentParser(prog="argus")
    parser.add_argument("--dry-run", action="store_true", help="log the report, don't send it")
    parser.add_argument(
        "--no-batch", action="store_true", help="direct API call instead of the batch API"
    )
    args = parser.parse_args()

    settings = Settings()
    if args.no_batch:
        settings.anthropic_batch = False
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # httpx logs full request URLs at INFO, and the Telegram URL carries the bot token
    logging.getLogger("httpx").setLevel(logging.WARNING)
    sys.exit(run(settings, dry_run=args.dry_run))


if __name__ == "__main__":
    main()
