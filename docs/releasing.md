# Release process

Releases use an explicit human gate. Pushing a `v*` tag runs the complete build
matrix but does not publish packages automatically.

## Prepare

1. Choose a new version that has never been published. Do not reuse a version
   after a partial or failed registry publish.
2. Update the root package version, every optional platform dependency, and
   `lib/version.ml`.
3. Generate the lockfile with the repository's pinned Node/npm toolchain:

   ```sh
   npm install --package-lock-only --ignore-scripts --no-audit --no-fund
   ```

4. Run the local gates:

   ```sh
   npm ci --ignore-scripts --no-audit --no-fund
   npm run audit:release
   npm run audit:dependencies
   npm run test:parity
   ```

5. Merge only after the Linux, macOS, Windows, GNU, and musl jobs are green.

## Build the tag

Create a `v<package-version>` tag from the verified default-branch commit and
push it. The tag run builds and validates every package artifact. The release
metadata audit rejects a tag that does not exactly match the package, lockfile,
OCaml binary, or optional package versions.

## Publish

Dispatch the **Build** workflow against the verified tag with GitHub CLI:

```sh
gh workflow run build.yml \
  --ref "v<package-version>" \
  -f publish_npm=true
```

The tag reference is deliberate: the GitHub web **Run workflow** control selects
branches, while publication is allowed only for an explicit manual dispatch of
a `v*` tag. The manual run rebuilds every target, validates artifact names,
platform selectors, versions, executable modes, and checksums, then publishes
platform packages before the root package.

After publishing, verify the root and all seven platform packages on npm, run a
clean alias install on a supported host, and create the GitHub release notes.
Treat the npm registry and GitHub release as separate checks; a green build does
not prove either external publication succeeded.
