# The release recipes pass their arguments as positional parameters ("$@").
# Never write {{tag}} or {{args}} into these lines: just pastes such values
# into the shell command as text, and the shell then runs a crafted value as
# code.

# Sign a draft release on your machine, then start the CI workflow that verifies and publishes it
[positional-arguments]
sign-release tag *args:
	./dev-scripts/release/sign-release.sh "$@"

# Create or update the encrypted file with your release signing secrets
[positional-arguments]
release-signing-setup *args:
	./dev-scripts/release/init-secrets.sh "$@"
