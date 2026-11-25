#!/bin/sh
# Unpacks the speech model (Models/Parakeet.zip) straight into the keyboard extension in Xcode's
# build folder. The project itself only holds the ZIP.
#
# Run by the build phase "Unpack Speech Model" of the target iDiktatKeyboard. Thanks to its input
# and output paths, Xcode runs it only when the ZIP (or this script) changed or the unpacked model
# is missing from the build folder. The build sandbox (ENABLE_USER_SCRIPT_SANDBOXING) only allows
# writing the declared output, so the script unpacks directly into it, without a temporary folder.

set -eu

zip_path=${1:?"missing ZIP path"}
destination=${2:?"missing destination"}   # .../iDiktatKeyboard.appex/Parakeet

if [ ! -f "$zip_path" ]; then
    echo "error: Speech model not found: $zip_path. Download Parakeet.zip from the model-v1 release and put it into Models/ (see Models/README.md)." >&2
    exit 1
fi
# The ZIP holds a single top-level folder "Parakeet", which becomes the destination.
if [ "$(basename "$destination")" != "Parakeet" ]; then
    echo "error: The destination must be a folder named Parakeet: $destination" >&2
    exit 1
fi

rm -rf "$destination"
unzip -q "$zip_path" 'Parakeet/*' -x '*/.DS_Store' -d "$(dirname "$destination")"

for part in Preprocessor Encoder_v2 Decoder JointDecisionv3; do
    if [ ! -d "$destination/$part.mlmodelc" ]; then
        echo "error: $zip_path does not contain Parakeet/$part.mlmodelc. Download Parakeet.zip again from the model-v1 release." >&2
        exit 1
    fi
done
# Marks the output as up to date, so Xcode skips this phase until the ZIP changes.
touch "$destination"
