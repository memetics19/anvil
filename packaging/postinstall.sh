#!/bin/sh
# Runs after the .deb or .rpm installs anvil. It only prints the next step.
echo "anvil is installed. Next, as your own user (not root): anvil fetch && anvil doctor"
exit 0
