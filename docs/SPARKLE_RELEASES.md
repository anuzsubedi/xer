# Sparkle releases

The macOS app checks `https://xer.anuz.dev/appcast.xml`. The release workflow
publishes that feed to the `anuzsubedi/xer-web` repository after publishing the
GitHub release.

## Required GitHub Actions secrets

### `SPARKLE_PRIVATE_KEY`

On the release Mac, export the Sparkle key to a temporary file and copy the
file contents into this secret:

```bash
/path/to/Sparkle/bin/generate_keys --account xer -x /tmp/xer-sparkle-private-key
cat /tmp/xer-sparkle-private-key
```

Never commit or paste this key into the repository.

### `XER_WEB_REPO_TOKEN`

Create a fine-grained GitHub token with **Contents: Read and write** access to
`anuzsubedi/xer-web`. The release workflow uses it to commit the generated
`public/appcast.xml` to the web repository, which Vercel then deploys.

The workflow downloads Sparkle 2.9.4, generates signatures using
`SPARKLE_PRIVATE_KEY`, preserves existing feed entries, adds the new GitHub
Release asset, and pushes the updated feed to `xer-web`.
