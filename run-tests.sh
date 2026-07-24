#!/usr/bin/env bash

# Runs the live cache integration tests against the iOS simulator.
#
# The session is read from this project's own `.env` (see `.env.example`), keeping the project
# self-contained. In CI there is usually no `.env` at all — export the same variables from your
# secret store instead and the script uses them directly.
#
# Resolution order:
#   1. the variables already set in the environment (CI)
#   2. this project's .env, or $FILEN_TEST_ENV if set
#
# Values are read here on the host and handed to xcodebuild as TEST_RUNNER_-prefixed environment
# variables, which it forwards into the test process with the prefix stripped. Nothing reads the
# .env from inside the simulator.
#
# Usage: ./run-tests.sh [additional xcodebuild args...]

set -u
set -o pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

required=(EMAIL MASTER_KEYS API_KEY PRIVATE_KEY AUTH_VERSION BASE_FOLDER_UUID)

all_set() {
	local name
	for name in "${required[@]}"; do
		[ -n "${!name:-}" ] || return 1
	done
	return 0
}

# Reads `KEY=value` / `KEY = value` pairs out of an env file.
#
# Parsed rather than sourced, for two reasons: sourcing executes whatever is in the file, and it
# only accepts the shell spelling — the checked-in .env.example uses the xcconfig spelling with
# spaces around the `=`, so both have to work. Only whole-line comments are stripped: `//` and `#`
# occur inside values (a base64 PRIVATE_KEY routinely contains `//`), so a trailing-comment strip
# would silently corrupt the key. Assignments are allowlisted to the variables below, so the file
# cannot set anything else.
load_env_file() {
	local file=$1 line key value name
	while IFS= read -r line || [ -n "$line" ]; do
		# Whole-line comments and blank lines.
		case "${line#"${line%%[![:space:]]*}"}" in
			'#'* | '//'* | '') continue ;;
		esac

		[[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
		key=${BASH_REMATCH[1]}
		value=${BASH_REMATCH[2]}

		# Trim trailing whitespace, then a single matching pair of surrounding quotes.
		value=${value%"${value##*[![:space:]]}"}
		if [ ${#value} -ge 2 ]; then
			case "$value" in
				'"'*'"') value=${value:1:${#value}-2} ;;
				"'"*"'") value=${value:1:${#value}-2} ;;
			esac
		fi

		for name in "${required[@]}"; do
			if [ "$key" = "$name" ]; then
				printf -v "$key" '%s' "$value"
				export "$key"
				break
			fi
		done
	done <"$file"
}

if all_set; then
	echo "==> using session from the environment"
else
	env_file=${FILEN_TEST_ENV:-$script_dir/.env}

	if [ ! -f "$env_file" ]; then
		echo "error: no session available." >&2
		echo "  Expected either the ${required[*]} variables in the environment," >&2
		echo "  or a .env defining them at: $env_file" >&2
		echo "  Copy .env.example to .env, or set FILEN_TEST_ENV=/path/to/.env." >&2
		exit 1
	fi

	echo "==> using session from ${env_file}"
	load_env_file "$env_file"
fi

missing=()
for name in "${required[@]}"; do
	[ -n "${!name:-}" ] || missing+=("$name")
done
if [ ${#missing[@]} -gt 0 ]; then
	echo "error: missing required session variables: ${missing[*]}" >&2
	exit 1
fi

destination=${FILEN_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro}

TEST_RUNNER_EMAIL="$EMAIL" \
	TEST_RUNNER_MASTER_KEYS="$MASTER_KEYS" \
	TEST_RUNNER_API_KEY="$API_KEY" \
	TEST_RUNNER_PRIVATE_KEY="$PRIVATE_KEY" \
	TEST_RUNNER_AUTH_VERSION="$AUTH_VERSION" \
	TEST_RUNNER_BASE_FOLDER_UUID="$BASE_FOLDER_UUID" \
	xcodebuild \
	-project "$script_dir/FilenFileProvider.xcodeproj" \
	-scheme FilenFileProviderTests \
	-destination "$destination" \
	-configuration Debug \
	CODE_SIGNING_ALLOWED=NO \
	test "$@"
