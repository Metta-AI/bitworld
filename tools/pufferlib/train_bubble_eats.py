from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from train_bitworld_env import main


if __name__ == "__main__":
    if "--env" not in sys.argv[1:]:
        sys.argv = [sys.argv[0], "--env", "bubble_eats", *sys.argv[1:]]
    main()
