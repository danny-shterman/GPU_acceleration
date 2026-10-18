import sys
import logging
from logging.handlers import RotatingFileHandler

path = "/workspace/kit/results/vllm_rocprof_server.log"

handler = RotatingFileHandler(
    path,
    maxBytes=100 * 1024 * 1024,
    backupCount=2,
)

handler.setFormatter(logging.Formatter("%(message)s"))

logger = logging.getLogger("vllm")
logger.setLevel(logging.INFO)
logger.addHandler(handler)
logger.propagate = False

for line in sys.stdin:
    logger.info(line.rstrip("\n"))

