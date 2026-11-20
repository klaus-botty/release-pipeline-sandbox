# Release pipeline sandbox

This repository tests a release pipeline in three steps. First, a CI workflow builds sample files and puts them in a draft release. Next, a maintainer checks and signs the files on their own machine. Last, a second CI workflow verifies the signatures and publishes the release.

All files here are stand-ins. The build writes random bytes, and all keys are throwaway test keys. Nothing in this repository is a real product, so do not install or trust any file from its releases.
