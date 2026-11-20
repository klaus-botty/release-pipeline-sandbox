# Sign a draft release on your machine, then start the CI workflow that verifies and publishes it
sign-release tag *args:
	./dev-scripts/release/sign-release.sh {{tag}} {{args}}

# Create the encrypted file with your release signing secrets (one time)
release-signing-setup *args:
	./dev-scripts/release/init-secrets.sh {{args}}
