# GPU_acceleration

make_mi300x_qwen3_profile_kit.sh creates the complete directory, validates the generated files, generates the full DOT DFG, and produces mi300x_qwen3_profile_kit.zip on your machine.

cd mi300x_qwen3_profile_kit

cp .env.example .env
source .env

./01_start_container.sh

Then verify:

docker ps -a --filter name=mi300x-qwen3-profile
